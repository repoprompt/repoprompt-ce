import Combine
import Foundation
import SwiftUI

@MainActor
class TokenCountingViewModel: ObservableObject {
    // MARK: - Token Counting Properties

    @Published private(set) var tokenCount: String = "0.00k"
    @Published private(set) var tokenCountFilesOnly: String = "0.00k"
    @Published private(set) var charCount: Int = 0
    @Published private(set) var totalTokenCount: Int = 0
    @Published private(set) var totalTokenCountFilesOnly: Int = 0
    @Published private(set) var gitDiffTokenCount: Int = 0
    @Published private(set) var gitDiffTokenCountString: String = "0.00k"
    @Published private(set) var folderTokenInfo: [String: TokenInfo] = [:]
    @Published private(set) var fileTokenInfo: [UUID: TokenInfo] = [:]
    @Published private(set) var codeMapFileCount: Int = 0
    @Published private(set) var codeMapTokenCount: Int = 0
    @Published private(set) var cachedFileAPIs: [FileAPI] = []
    @Published private(set) var fileTreeContent: String = ""
    @Published private(set) var codeMapContent: String = ""
    @Published private(set) var scannedLanguages: Set<LanguageType> = []
    @Published private(set) var copyContextTotalTokens: Int = 0
    @Published private(set) var copyContextTokenCountString: String = "0.00k"

    /// Combined property preserving legacy behaviour
    var combinedTreeAndCodeMapContent: String {
        [fileTreeContent, codeMapContent]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Total display tokens for files in the current mode.
    /// In .selected mode, this combines non-API file tokens + codemap tokens.
    /// Use this for consistent file token display across UI surfaces.
    var totalFileTokensDisplay: Int {
        totalTokenCountFilesOnly + codeMapTokenCount
    }

    /// Formatted string for total file tokens display.
    var fileTokensDisplayString: String {
        String(format: "%.2fk", Double(totalFileTokensDisplay) / 1000.0)
    }

    let tokenCalculationCompletedPublisher = PassthroughSubject<Void, Never>()

    // MARK: - Dirty Flags

    struct DirtyKind: OptionSet {
        let rawValue: Int
        static let selection = DirtyKind(rawValue: 1 << 0) // selected files changed
        static let fileTree = DirtyKind(rawValue: 1 << 1) // tree needs rebuild
        static let codeMap = DirtyKind(rawValue: 1 << 2) // code-map cache changed
        static let settings = DirtyKind(rawValue: 1 << 3) // settings affecting baseline
        static let gitDiff = DirtyKind(rawValue: 1 << 4) // just diff tokens changed
        static let promptText = DirtyKind(rawValue: 1 << 5) // user instructions text changed
        static let instructions = DirtyKind(rawValue: 1 << 6) // stored/meta instructions changed
    }

    private let heavyDirtyKinds: DirtyKind = [.selection, .fileTree, .codeMap, .settings]
    private var pendingDirty: DirtyKind = []

    /// Cached components to support light, incremental recomputation.
    private var didComputeBaseline: Bool = false
    private var lastBaseWithoutUserText: Int = 0 // Everything except user prompt/instructions
    private var lastPromptTokens: Int = 0 // Tokens for prompt text only
    private var lastDuplicatePromptTokens: Int = 0 // Duplicate prompt tokens (if setting is on)
    private var lastInstructionsTokens: Int = 0 // Tokens for meta/stored instructions
    private var lastGitDiffTokens: Int = 0
    private var lastFileTreeTokens: Int = 0

    // MARK: - Private Properties

    private static let tokenUpdateDebounceNanoseconds: UInt64 = 500_000_000

    private let tokenCalculationService = TokenCalculationService()
    private let promptContextAccountingService = PromptContextAccountingService()
    private var tokenUpdateDebounceTask: Task<Void, Never>?
    private var updateTokenCountTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var isTokenCountSchedulerActive = false
    private var isImmediateRecountInProgress = false
    private var tokenCountSchedulerGeneration: UInt64 = 0
    private var selectionObservationRevision: UInt64 = 0
    private var lastObservedSelectionObservationRevision: UInt64 = 0
    private var lastPredominantLanguage: String = "Swift"
    private var automaticRecountSuspendDepth: Int = 0
    private var lastPublishedSelection: StoredSelection?
    #if DEBUG
        private var debugBeforeTokenCalculationForTesting: (@MainActor @Sendable () async -> Void)?
        private var debugTokenCalculationStartCount = 0
    #endif

    // MARK: - Dependencies

    private weak var fileManager: WorkspaceFilesViewModel?
    private weak var gitViewModel: GitViewModel?
    private var getPromptText: (() -> String)?
    private var getSelectedInstructionsText: (() -> String)?
    private var getSettings: (() -> TokenCalculationSettings)?
    private var getCopyContext: (() -> CopyContextSnapshot)?
    private var getStoredSelection: (@MainActor () -> StoredSelection?)?

    // MARK: - Settings Structure

    struct TokenCalculationSettings {
        let fileTreeOption: FileTreeOption
        let codeMapUsage: CodeMapUsage
        let filePathDisplayOption: FilePathDisplay
        let includeFilesInClipboard: Bool
        let duplicateUserInstructionsAtTop: Bool
        let onlyIncludeRootsWithSelectedFiles: Bool
        let codeMapsGloballyDisabled: Bool
    }

    struct CopyContextSnapshot {
        let includeFiles: Bool
        let includeUserPrompt: Bool
        let includeMetaPrompts: Bool
        let includeFileTree: Bool
        let fileTreeMode: FileTreeOption
        let codeMapUsage: CodeMapUsage
        let gitInclusion: GitInclusion
        let duplicateUserInstructionsAtTop: Bool

        static var `default`: CopyContextSnapshot {
            CopyContextSnapshot(
                includeFiles: true,
                includeUserPrompt: true,
                includeMetaPrompts: true,
                includeFileTree: true,
                fileTreeMode: .auto,
                codeMapUsage: .none,
                gitInclusion: .none,
                duplicateUserInstructionsAtTop: false
            )
        }
    }

    // MARK: - Initialization

    init() {
        // Initialize with empty state
    }

    func configure(
        fileManager: WorkspaceFilesViewModel,
        gitViewModel: GitViewModel,
        getPromptText: @escaping () -> String,
        getSelectedInstructionsText: @escaping () -> String,
        getSettings: @escaping () -> TokenCalculationSettings,
        getCopyContext: @escaping () -> CopyContextSnapshot,
        getStoredSelection: @escaping @MainActor () -> StoredSelection?
    ) {
        self.fileManager = fileManager
        self.gitViewModel = gitViewModel
        self.getPromptText = getPromptText
        self.getSelectedInstructionsText = getSelectedInstructionsText
        self.getSettings = getSettings
        self.getCopyContext = getCopyContext
        self.getStoredSelection = getStoredSelection

        setupObservers()
        startTokenCountUpdateTimer()
    }

    // MARK: - Setup and Observer Configuration

    private func setupObservers() {
        guard let fileManager else { return }

        fileManager.$selectedFiles
            .dropFirst()
            .sink { [weak self] _ in
                self?.recordSelectionProjectionChanged()
            }
            .store(in: &cancellables)

        fileManager.$selectionSlicesByFileID
            .dropFirst()
            .sink { [weak self] _ in
                self?.recordSelectionProjectionChanged()
            }
            .store(in: &cancellables)

        fileManager.codeMapUpdatePublisher
            .sink { [weak self] in
                self?.markDirty(.codeMap)
            }
            .store(in: &cancellables)

        // NEW: Clear caches when roots are added/removed/rebuilt so UI doesn't show stale data
        fileManager.fileSystemChangedPublisher
            .sink { [weak self] in
                self?.handleFileSystemTopologyChanged()
            }
            .store(in: &cancellables)

        // NEW: Explicitly handle the "all folders unloaded" signal
        fileManager.allFoldersUnloadedPublisher
            .sink { [weak self] in
                self?.handleFileSystemTopologyChanged()
            }
            .store(in: &cancellables)

        // Observe git diff mode changes to recalculate only diff tokens
        gitViewModel?.$gitDiffInclusionMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.markDirty(.gitDiff)
            }
            .store(in: &cancellables)

        gitViewModel?.$selectedDiffBranch
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.markDirty(.gitDiff)
            }
            .store(in: &cancellables)

        gitViewModel?.$unstagedFiles
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.markDirty(.gitDiff)
            }
            .store(in: &cancellables)

        gitViewModel?.$selectedRootFolder
            .dropFirst()
            .map { $0?.fullPath }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.markDirty(.gitDiff)
            }
            .store(in: &cancellables)
    }

    // MARK: - Dirty Update Scheduling

    func startTokenCountUpdateTimer() {
        if !isTokenCountSchedulerActive {
            tokenCountSchedulerGeneration &+= 1
        }
        isTokenCountSchedulerActive = true
        scheduleTokenCountUpdateIfNeeded()
    }

    func stopTokenCountUpdateTimer() async {
        isTokenCountSchedulerActive = false
        tokenCountSchedulerGeneration &+= 1
        tokenUpdateDebounceTask?.cancel()
        tokenUpdateDebounceTask = nil
        updateTokenCountTask?.cancel()
        updateTokenCountTask = nil
        await tokenCalculationService.shutdown()
    }

    private func scheduleTokenCountUpdateIfNeeded() {
        guard isTokenCountSchedulerActive,
              !isImmediateRecountInProgress,
              automaticRecountSuspendDepth == 0,
              !pendingDirty.isEmpty,
              updateTokenCountTask == nil
        else {
            return
        }

        let generation = tokenCountSchedulerGeneration
        tokenUpdateDebounceTask?.cancel()
        tokenUpdateDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.tokenUpdateDebounceNanoseconds)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  tokenCountSchedulerGeneration == generation
            else {
                return
            }
            tokenUpdateDebounceTask = nil
            startPendingTokenCountUpdate(generation: generation)
        }
    }

    private func startPendingTokenCountUpdate(generation: UInt64) {
        guard isTokenCountSchedulerActive,
              tokenCountSchedulerGeneration == generation,
              !isImmediateRecountInProgress,
              automaticRecountSuspendDepth == 0,
              !pendingDirty.isEmpty,
              updateTokenCountTask == nil
        else {
            return
        }

        // Snapshot and clear to coalesce changes; anything that happens during compute is queued for the next debounce.
        let kindsToProcess = pendingDirty
        pendingDirty = []

        let needsHeavy = !kindsToProcess.intersection(heavyDirtyKinds).isEmpty
        updateTokenCountTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if needsHeavy {
                await performTokenCountOffMainThread()
            } else {
                await recalculateLight(kinds: kindsToProcess)
            }
            guard tokenCountSchedulerGeneration == generation else { return }
            updateTokenCountTask = nil
            scheduleTokenCountUpdateIfNeeded()
        }
    }

    // MARK: - Dirty Markers (Public)

    /// Backwards-compatible "everything changed" flag (used by existing callers).
    func markDirty() {
        markDirty(.selection.union(.fileTree).union(.codeMap).union(.settings))
    }

    func markDirty(_ kind: DirtyKind) {
        pendingDirty.formUnion(kind)

        let currentSelectionRevision = selectionObservationRevision
        if kind.contains(.selection),
           resolveCopyContextSnapshot().includeFiles,
           currentSelectionRevision != lastObservedSelectionObservationRevision
        {
            updateTokenCountTask?.cancel()
        }
        lastObservedSelectionObservationRevision = currentSelectionRevision

        scheduleTokenCountUpdateIfNeeded()
    }

    private func recordSelectionProjectionChanged() {
        selectionObservationRevision &+= 1
        markDirty(.selection)
    }

    func markPromptDirty() {
        markDirty(.promptText)
    }

    func markInstructionsDirty() {
        markDirty(.instructions)
    }

    func markGitDiffDirty() {
        markDirty(.gitDiff)
    }

    func suspendAutomaticRecounts() {
        automaticRecountSuspendDepth += 1
    }

    func resumeAutomaticRecounts() {
        automaticRecountSuspendDepth = max(0, automaticRecountSuspendDepth - 1)
        if automaticRecountSuspendDepth == 0 {
            scheduleTokenCountUpdateIfNeeded()
        }
    }

    struct PublishedTokenSnapshot {
        let breakdown: TokenBreakdown
        let filesContentTokens: Int
        let codeMapTokens: Int
        let isComplete: Bool
        let isStale: Bool
        let refreshPending: Bool
    }

    func latestPublishedTokenSnapshot(for expectedSelection: StoredSelection?) -> PublishedTokenSnapshot {
        let selectionMatches = expectedSelection == nil || expectedSelection == lastPublishedSelection
        let calculationPending = tokenUpdateDebounceTask != nil || updateTokenCountTask != nil || isImmediateRecountInProgress
        let isComplete = didComputeBaseline
        let isStale = !pendingDirty.isEmpty || calculationPending || !selectionMatches
        if !isComplete {
            markDirty()
        } else if !selectionMatches {
            markDirty(.selection)
        }
        return PublishedTokenSnapshot(
            breakdown: latestTokenBreakdown(),
            filesContentTokens: totalTokenCountFilesOnly,
            codeMapTokens: codeMapTokenCount,
            isComplete: isComplete,
            isStale: isStale,
            refreshPending: !isComplete || isStale || tokenUpdateDebounceTask != nil || updateTokenCountTask != nil
        )
    }

    func latestPublishedTokenInfo(forFullPath fullPath: String) -> TokenInfo? {
        guard let fileID = fileManager?.findFileByFullPath(fullPath)?.id else { return nil }
        return fileTokenInfo[fileID]
    }

    #if DEBUG
        func setBeforeTokenCalculationForTesting(
            _ handler: (@MainActor @Sendable () async -> Void)?
        ) {
            debugBeforeTokenCalculationForTesting = handler
        }

        func tokenCalculationStartCountForTesting() -> Int {
            debugTokenCalculationStartCount
        }

        func debugTokenRecountStateFields() -> [String: String] {
            [
                "pendingDirtyRaw": "\(pendingDirty.rawValue)",
                "schedulerActive": "\(isTokenCountSchedulerActive)",
                "suspendDepth": "\(automaticRecountSuspendDepth)",
                "debouncePending": "\(tokenUpdateDebounceTask != nil)",
                "updatePending": "\(updateTokenCountTask != nil)",
                "immediateInProgress": "\(isImmediateRecountInProgress)",
                "didComputeBaseline": "\(didComputeBaseline)",
                "totalTokens": "\(totalTokenCount)",
                "fileTokens": "\(totalTokenCountFilesOnly)",
                "codeMapTokens": "\(codeMapTokenCount)",
                "fileTreeTokens": "\(lastFileTreeTokens)",
                "cachedFileAPIs": "\(cachedFileAPIs.count)"
            ]
        }

        private func debugSelectionFields(_ selection: StoredSelection) -> [String: String] {
            PromptTokenRecountDiagnostics.selectionFields(selection)
        }
    #endif

    @MainActor
    func forceImmediateRecount() async {
        #if DEBUG
            let forceStartMS = PromptTokenRecountDiagnostics.start()
            let replacedDebounceTask = tokenUpdateDebounceTask != nil
            let cancelledUpdateTask = updateTokenCountTask != nil
            var beginFields = debugTokenRecountStateFields()
            beginFields["replacedDebounceTask"] = "\(replacedDebounceTask)"
            beginFields["cancelledUpdateTask"] = "\(cancelledUpdateTask)"
            PromptTokenRecountDiagnostics.event("tokenRecount.force.begin", fields: beginFields)
        #endif
        tokenCountSchedulerGeneration &+= 1
        if tokenUpdateDebounceTask != nil || updateTokenCountTask != nil {
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.force.cancelPending",
                    fields: [
                        "debouncePending": "\(tokenUpdateDebounceTask != nil)",
                        "updatePending": "\(updateTokenCountTask != nil)",
                        "generation": "\(tokenCountSchedulerGeneration)"
                    ]
                )
            #endif
        }
        tokenUpdateDebounceTask?.cancel()
        tokenUpdateDebounceTask = nil
        updateTokenCountTask?.cancel()
        updateTokenCountTask = nil
        pendingDirty = []
        isImmediateRecountInProgress = true
        await performTokenCountOffMainThread()
        isImmediateRecountInProgress = false
        scheduleTokenCountUpdateIfNeeded()
        #if DEBUG
            var endFields = debugTokenRecountStateFields()
            endFields["outcome"] = Task.isCancelled ? "cancelled" : "completed"
            endFields["duration"] = forceStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
            PromptTokenRecountDiagnostics.event(Task.isCancelled ? "tokenRecount.force.cancelled" : "tokenRecount.force.end", fields: endFields)
        #endif
    }

    private func resolveCopyContextSnapshot() -> CopyContextSnapshot {
        getCopyContext?() ?? .default
    }

    private func currentStoredSelection(includeFiles: Bool) -> StoredSelection {
        guard includeFiles else { return StoredSelection() }
        if let selection = getStoredSelection?() {
            return selection
        }
        // Fallback for legacy/test uses where TokenCountingViewModel is configured
        // without a compose-tab owner. Normal compose-tab flows inject a provider
        // that publishes the active tab snapshot and reads ComposeTabState.selection.
        return fileManager?.snapshotSelection() ?? StoredSelection()
    }

    private func allStoreFileRecords(from store: WorkspaceFileContextStore) async -> [WorkspaceFileRecord] {
        let roots = await store.roots()
        var records: [WorkspaceFileRecord] = []
        for root in roots {
            await records.append(contentsOf: store.files(inRoot: root.id))
        }
        return records
    }

    private func predominantLanguage(
        from entries: [ResolvedPromptFileEntry],
        includeFiles: Bool,
        codeMapUsage: CodeMapUsage
    ) -> String {
        guard includeFiles else { return "Swift" }
        let languageFiles: [WorkspaceFileRecord] = if codeMapUsage == .selected {
            // `.selected` renders explicitly selected files as codemap entries, so they
            // should still participate in language inference like live selectedFiles did.
            deduplicatedFilesPreservingOrder(entries.map(\.file))
        } else {
            // For `.auto` and `.complete`, codemap entries can include unselected files;
            // prefer full/sliced selected files to avoid workspace-wide language bias.
            deduplicatedFilesPreservingOrder(entries.filter { !$0.isCodemap }.map(\.file))
        }
        guard !languageFiles.isEmpty else { return "Swift" }
        return SystemPromptService.predominantLanguage(from: languageFiles)
    }

    private func deduplicatedFilesPreservingOrder(_ files: [WorkspaceFileRecord]) -> [WorkspaceFileRecord] {
        var seen = Set<UUID>()
        var result: [WorkspaceFileRecord] = []
        for file in files where seen.insert(file.id).inserted {
            result.append(file)
        }
        return result
    }

    // MARK: - Token Calculation

    /// Heavy path (rebuild baseline and everything else).
    private func performTokenCountOffMainThread() async {
        #if DEBUG
            debugTokenCalculationStartCount += 1
            await debugBeforeTokenCalculationForTesting?()
            let calculateStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event("tokenRecount.calculate.begin", fields: debugTokenRecountStateFields())
        #endif
        guard let fileManager,
              let promptSource = getPromptText?(),
              let instructionsSource = getSelectedInstructionsText?(),
              let settings = getSettings?()
        else {
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.calculate.error",
                    fields: [
                        "reason": "missingDependencies",
                        "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return
        }

        let copySnapshot = resolveCopyContextSnapshot()
        let includeFiles = copySnapshot.includeFiles
        #if DEBUG
            let selectionSnapshotStartMS = PromptTokenRecountDiagnostics.start()
        #endif
        let selectionAtStart = includeFiles ? currentStoredSelection(includeFiles: true) : StoredSelection()
        #if DEBUG
            var selectionFields = debugSelectionFields(selectionAtStart)
            selectionFields["includeFiles"] = "\(includeFiles)"
            selectionFields["duration"] = selectionSnapshotStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
            PromptTokenRecountDiagnostics.event("tokenRecount.calculate.selectionSnapshot", fields: selectionFields)
        #endif
        let includeUserPrompt = copySnapshot.includeUserPrompt
        let includeMetaPrompts = copySnapshot.includeMetaPrompts
        let includeFileTree = copySnapshot.includeFileTree

        let promptText = includeUserPrompt ? promptSource : ""
        // For MCP system prompts, always include them even if includeMetaPrompts is false
        // (e.g., MCP Discover has includeMetaPrompts=false but still needs system prompt counted)
        let selectedInstructionsText = includeMetaPrompts ? instructionsSource : ""
        let duplicatePromptAtTop = includeUserPrompt ? copySnapshot.duplicateUserInstructionsAtTop : false

        let store = fileManager.workspaceFileContextStore
        #if DEBUG
            let allFilesStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event("tokenRecount.calculate.allFiles.begin")
        #endif
        let allFileRecords = await allStoreFileRecords(from: store)
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.allFiles.end",
                fields: [
                    "files": "\(allFileRecords.count)",
                    "duration": allFilesStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        guard !Task.isCancelled else {
            #if DEBUG
                PromptTokenRecountDiagnostics.event("tokenRecount.calculate.cancelled", fields: ["phase": "allFiles", "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"])
            #endif
            return
        }
        #if DEBUG
            let codemapAPIsStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event("tokenRecount.calculate.codemapAPIs.begin")
        #endif
        let storeFileAPIs = await store.allCodemapFileAPIs()
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.codemapAPIs.end",
                fields: [
                    "fileAPIs": "\(storeFileAPIs.count)",
                    "duration": codemapAPIsStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        guard !Task.isCancelled else {
            #if DEBUG
                PromptTokenRecountDiagnostics.event("tokenRecount.calculate.cancelled", fields: ["phase": "codemapAPIs", "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"])
            #endif
            return
        }

        // Cache the store-owned file APIs for reuse by legacy UI surfaces.
        cachedFileAPIs = storeFileAPIs

        // Derive and publish the set of detected languages from store-owned file records.
        let detectedExts = allFileRecords.map { (($0.name as NSString).pathExtension).lowercased() }
        let detectedLangs = detectedExts.compactMap { SyntaxManager.shared.extensionToLanguage[$0] }
        scannedLanguages = Set(detectedLangs)

        let effectiveCodeMapUsage = copySnapshot.codeMapUsage
        let accountingCodeMapUsage: CodeMapUsage = includeFiles ? effectiveCodeMapUsage : .none
        let accountingSelection = includeFiles ? selectionAtStart : StoredSelection()

        let effectiveFileTreeOption: FileTreeOption = includeFileTree ? copySnapshot.fileTreeMode : .none
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.context",
                fields: [
                    "includeFiles": "\(includeFiles)",
                    "includeFileTree": "\(includeFileTree)",
                    "fileTreeMode": "\(effectiveFileTreeOption)",
                    "codeMapUsage": "\(accountingCodeMapUsage)",
                    "gitInclusion": "\(copySnapshot.gitInclusion)"
                ]
            )
        #endif
        let fileTreeInput: TokenCalculationFileTreeInput
        if includeFileTree, effectiveFileTreeOption != .none {
            #if DEBUG
                let fileTreeStartMS = PromptTokenRecountDiagnostics.start()
                PromptTokenRecountDiagnostics.event("tokenRecount.calculate.fileTree.begin")
            #endif
            let fileTreeSnapshot = await store.makeFileTreeSelectionSnapshot(
                selection: accountingSelection,
                request: WorkspaceFileTreeSnapshotRequest(
                    mode: WorkspaceFileTreeSnapshotMode(fileTreeOption: effectiveFileTreeOption),
                    filePathDisplay: settings.filePathDisplayOption,
                    onlyIncludeRootsWithSelectedFiles: settings.onlyIncludeRootsWithSelectedFiles,
                    includeLegend: true,
                    showCodeMapMarkers: !settings.codeMapsGloballyDisabled,
                    rootScope: .allLoaded
                ),
                profile: .uiAssisted
            )
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.calculate.fileTree.end",
                    fields: [
                        "roots": "\(fileTreeSnapshot.roots.count)",
                        "duration": fileTreeStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            fileTreeInput = .snapshot(fileTreeSnapshot)
        } else {
            fileTreeInput = .none
        }
        guard !Task.isCancelled else {
            #if DEBUG
                PromptTokenRecountDiagnostics.event("tokenRecount.calculate.cancelled", fields: ["phase": "fileTree", "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"])
            #endif
            return
        }
        let accountingRequest = PromptContextAccountingRequest(
            selection: accountingSelection,
            promptText: promptText,
            selectedInstructionsText: selectedInstructionsText,
            duplicateUserInstructionsAtTop: duplicatePromptAtTop,
            fileTree: fileTreeInput,
            codeMapUsage: accountingCodeMapUsage,
            filePathDisplay: settings.filePathDisplayOption,
            rootScope: .allLoaded,
            pathLocateProfile: .uiAssisted
        )
        #if DEBUG
            let accountingStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event("tokenRecount.calculate.accounting.begin")
        #endif
        let accountingResult = await promptContextAccountingService.calculatePromptStats(
            request: accountingRequest,
            store: store
        )
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.accounting.end",
                fields: [
                    "resolvedEntries": "\(accountingResult.resolvedEntries.count)",
                    "promptEntries": "\(accountingResult.promptFileEntrySnapshots.count)",
                    "missingPaths": "\(accountingResult.missingPaths.count)",
                    "invalidPaths": "\(accountingResult.invalidPaths.count)",
                    "codemapsUsed": "\(accountingResult.codemapSnapshotsUsed.count)",
                    "duration": accountingStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        guard !Task.isCancelled else {
            #if DEBUG
                PromptTokenRecountDiagnostics.event("tokenRecount.calculate.cancelled", fields: ["phase": "accounting", "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"])
            #endif
            return
        }

        let predominantLanguage = predominantLanguage(
            from: accountingResult.resolvedEntries,
            includeFiles: includeFiles,
            codeMapUsage: accountingCodeMapUsage
        )
        let result = accountingResult.tokenResult

        // Git diff tokens: only count generated diffs from GitViewModel when no artifact files are selected.
        // Artifact files (_git_data/*.diff/*.patch) are already counted as normal files in calculatePromptStats,
        // so we don't double-count them here. gitDiffTokenCount represents ONLY generated diffs.
        let resolvedFileEntries = includeFiles ? accountingResult.resolvedEntries : []
        let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(resolvedFileEntries)
        let hasSelectedArtifacts = !diffEntries.isEmpty

        var gitDiffTokens = 0
        #if DEBUG
            let gitDiffStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.gitDiff.begin",
                fields: [
                    "hasSelectedArtifacts": "\(hasSelectedArtifacts)",
                    "gitInclusion": "\(copySnapshot.gitInclusion)"
                ]
            )
        #endif
        if !hasSelectedArtifacts, let gitViewModel {
            // No artifact files selected - use GitViewModel to generate diff if git inclusion is enabled
            switch copySnapshot.gitInclusion {
            case .none:
                break
            case .selected:
                if let diff = await gitViewModel.getDiffUsing(inclusionMode: .selectedFiles) {
                    gitDiffTokens = TokenCalculationService.estimateTokens(for: diff)
                }
            case .complete:
                if let diff = await gitViewModel.getDiffUsing(inclusionMode: .all) {
                    gitDiffTokens = TokenCalculationService.estimateTokens(for: diff)
                }
            }
        }
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.gitDiff.end",
                fields: [
                    "gitDiffTokens": "\(gitDiffTokens)",
                    "duration": gitDiffStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        // When artifact files ARE selected, gitDiffTokens stays 0 - those files are counted as normal files in calculatePromptStats
        guard !Task.isCancelled else {
            #if DEBUG
                PromptTokenRecountDiagnostics.event("tokenRecount.calculate.cancelled", fields: ["phase": "gitDiff", "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"])
            #endif
            return
        }
        #if DEBUG
            let consistencyStartMS = PromptTokenRecountDiagnostics.start()
        #endif
        if includeFiles, currentStoredSelection(includeFiles: true) != selectionAtStart {
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.calculate.selectionChanged",
                    fields: ["duration": consistencyStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"]
                )
            #endif
            markDirty(.selection)
            return
        }
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.selectionConsistent",
                fields: ["duration": consistencyStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"]
            )
        #endif

        let copyTotal = result.totalTokenCount + gitDiffTokens
        let copyTokenString = String(format: "%.2fk", Double(copyTotal) / 1000.0)

        #if DEBUG
            let publishStartMS = PromptTokenRecountDiagnostics.start()
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.publish.begin",
                fields: [
                    "resolvedEntries": "\(accountingResult.resolvedEntries.count)",
                    "fileTokenInfos": "\(result.fileTokenInfo.count)",
                    "folderTokenInfos": "\(result.folderTokenInfo.count)",
                    "totalTokens": "\(copyTotal)",
                    "fileTokens": "\(result.totalTokenCountFilesOnly)",
                    "codeMapTokens": "\(result.codeMapTokenCount)",
                    "fileTreeTokens": "\(result.fileTreeTokenCountRaw)"
                ]
            )
        #endif
        fileTokenInfo = remapStoreFileTokenInfo(
            result.fileTokenInfo,
            resolvedEntries: accountingResult.resolvedEntries,
            fileManager: fileManager
        )
        folderTokenInfo = result.folderTokenInfo
        fileTreeContent = result.fileTreeContent
        codeMapContent = result.codeMapContent
        lastFileTreeTokens = result.fileTreeTokenCountRaw
        charCount = result.charCount
        totalTokenCount = copyTotal
        tokenCount = copyTokenString
        tokenCountFilesOnly = result.tokenCountFilesOnlyString
        totalTokenCountFilesOnly = result.totalTokenCountFilesOnly
        codeMapFileCount = result.codeMapFileCount
        codeMapTokenCount = result.codeMapTokenCount
        lastPredominantLanguage = predominantLanguage

        gitDiffTokenCount = gitDiffTokens
        gitDiffTokenCountString = String(format: "%.2fk", Double(gitDiffTokens) / 1000.0)

        let promptTokensLocal = TokenCalculationService.estimateTokens(for: promptText)
        let instructionsTokensLocal = TokenCalculationService.estimateTokens(for: selectedInstructionsText)
        let duplicatePromptTokensLocal = duplicatePromptAtTop ? promptTokensLocal : 0

        lastBaseWithoutUserText = max(
            0,
            result.totalTokenCount - promptTokensLocal - duplicatePromptTokensLocal - instructionsTokensLocal
        )
        lastPromptTokens = promptTokensLocal
        lastDuplicatePromptTokens = duplicatePromptTokensLocal
        lastInstructionsTokens = instructionsTokensLocal
        lastGitDiffTokens = gitDiffTokens
        lastPublishedSelection = selectionAtStart
        copyContextTotalTokens = copyTotal
        copyContextTokenCountString = copyTokenString
        didComputeBaseline = true
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.publish.apply.end",
                fields: [
                    "mappedFileTokenInfos": "\(fileTokenInfo.count)",
                    "duration": publishStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        tokenCalculationCompletedPublisher.send()
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.end",
                fields: [
                    "outcome": Task.isCancelled ? "cancelled" : "completed",
                    "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    private func remapStoreFileTokenInfo(
        _ storeFileTokenInfo: [UUID: TokenInfo],
        resolvedEntries: [ResolvedPromptFileEntry],
        fileManager: WorkspaceFilesViewModel
    ) -> [UUID: TokenInfo] {
        var mapped: [UUID: TokenInfo] = [:]
        for entry in resolvedEntries {
            guard let tokenInfo = storeFileTokenInfo[entry.file.id],
                  let liveFile = fileManager.findFileByFullPath(entry.file.standardizedFullPath)
            else { continue }
            mapped[liveFile.id] = tokenInfo
        }
        return mapped
    }

    /// Light path (prompt text and/or meta instructions and/or git diff only).
    private func recalculateLight(kinds: DirtyKind) async {
        guard didComputeBaseline,
              let promptSource = getPromptText?(),
              let instructionsSource = getSelectedInstructionsText?()
        else {
            await performTokenCountOffMainThread()
            return
        }

        let copySnapshot = resolveCopyContextSnapshot()
        let includeUserPrompt = copySnapshot.includeUserPrompt
        let includeMetaPrompts = copySnapshot.includeMetaPrompts
        let promptText = includeUserPrompt ? promptSource : ""
        let selectedInstructionsText = includeMetaPrompts ? instructionsSource : ""
        let duplicatePrompt = includeUserPrompt ? copySnapshot.duplicateUserInstructionsAtTop : false

        let promptTokens = TokenCalculationService.estimateTokens(for: promptText)
        let duplicatePromptTokens = duplicatePrompt ? promptTokens : 0
        let instructionsTokens = TokenCalculationService.estimateTokens(for: selectedInstructionsText)

        var gitDiffTokens = gitDiffTokenCount
        if kinds.contains(.gitDiff) {
            if let fileManager {
                // Check if artifact files are selected - if so, they're already counted as normal files.
                let hasSelectedArtifacts: Bool
                if copySnapshot.includeFiles {
                    let store = fileManager.workspaceFileContextStore
                    let selection = currentStoredSelection(includeFiles: true)
                    let resolution = await promptContextAccountingService.resolveEntries(
                        selection: selection,
                        store: store,
                        rootScope: .allLoaded,
                        profile: .uiAssisted,
                        codeMapUsage: copySnapshot.includeFiles ? copySnapshot.codeMapUsage : .none
                    )
                    let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(resolution.entries)
                    hasSelectedArtifacts = !diffEntries.isEmpty
                } else {
                    hasSelectedArtifacts = false
                }

                if hasSelectedArtifacts {
                    // Artifact files are selected - they're counted as normal files, not as gitDiffTokens
                    gitDiffTokens = 0
                } else if let gitViewModel {
                    // No artifact files - use GitViewModel to generate diff if git inclusion is enabled
                    switch copySnapshot.gitInclusion {
                    case .none:
                        gitDiffTokens = 0
                    case .selected:
                        if let diff = await gitViewModel.getDiffUsing(inclusionMode: .selectedFiles) {
                            gitDiffTokens = TokenCalculationService.estimateTokens(for: diff)
                        } else {
                            gitDiffTokens = 0
                        }
                    case .complete:
                        if let diff = await gitViewModel.getDiffUsing(inclusionMode: .all) {
                            gitDiffTokens = TokenCalculationService.estimateTokens(for: diff)
                        } else {
                            gitDiffTokens = 0
                        }
                    }
                } else {
                    gitDiffTokens = 0
                }
            } else {
                gitDiffTokens = 0
            }
            gitDiffTokenCount = gitDiffTokens
            gitDiffTokenCountString = String(format: "%.2fk", Double(gitDiffTokens) / 1000.0)
            lastGitDiffTokens = gitDiffTokens
        }

        let mainTotal = lastBaseWithoutUserText + promptTokens + duplicatePromptTokens + instructionsTokens
        let totalWithGit = mainTotal + gitDiffTokens

        let copyTokenString = String(format: "%.2fk", Double(totalWithGit) / 1000.0)
        totalTokenCount = totalWithGit
        tokenCount = copyTokenString
        copyContextTotalTokens = totalWithGit
        copyContextTokenCountString = copyTokenString

        lastPromptTokens = promptTokens
        lastDuplicatePromptTokens = duplicatePromptTokens
        lastInstructionsTokens = instructionsTokens

        tokenCalculationCompletedPublisher.send()
    }

    // MARK: - File Tree Properties

    var fileTreeTokenCount: Double {
        Double(lastFileTreeTokens) / 1000.0
    }

    var tooManyFileTreeTokens: Bool {
        fileTreeTokenCount > 10
    }

    struct TokenBreakdown {
        let total: Int
        let files: Int
        let prompt: Int
        let meta: Int
        let fileTree: Int
        let git: Int
        let other: Int
    }

    func latestTokenBreakdown() -> TokenBreakdown {
        let promptSource = getPromptText?() ?? ""
        let instructionsSource = getSelectedInstructionsText?() ?? ""
        let promptTokens = didComputeBaseline
            ? (lastPromptTokens + lastDuplicatePromptTokens)
            : (promptSource.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: promptSource))
        let metaTokens = didComputeBaseline
            ? lastInstructionsTokens
            : (instructionsSource.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: instructionsSource))
        let gitTokens = didComputeBaseline ? lastGitDiffTokens : 0
        let fileTreeTokens = didComputeBaseline
            ? lastFileTreeTokens
            : (fileTreeContent.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: fileTreeContent))
        let filesTokens = totalTokenCountFilesOnly
        let total = didComputeBaseline
            ? totalTokenCount
            : (promptTokens + filesTokens + metaTokens + gitTokens + fileTreeTokens)
        let otherTokens = max(total - (filesTokens + promptTokens + metaTokens + gitTokens + fileTreeTokens), 0)
        return TokenBreakdown(
            total: total,
            files: filesTokens,
            prompt: promptTokens,
            meta: metaTokens,
            fileTree: fileTreeTokens,
            git: gitTokens,
            other: otherTokens
        )
    }

    // MARK: - Token Breakdown

    var tokenBreakdownDescription: String {
        var parts: [String] = []

        if totalTokenCountFilesOnly > 0 {
            parts.append("• Files: \(tokenCountFilesOnly)")
        }

        if codeMapTokenCount > 0 {
            parts.append("• Code Maps: \(String(format: "%.2fk", Double(codeMapTokenCount) / 1000.0))")
        }

        if gitDiffTokenCount > 0 {
            parts.append("• Git Diff: \(gitDiffTokenCountString)")
        }

        let treeTokens = Int(fileTreeTokenCount * 1000)
        if treeTokens > 0 {
            parts.append("• File Tree: \(String(format: "%.2fk", fileTreeTokenCount))")
        }

        // Add other components like prompt text, instructions, etc.
        let otherTokens = totalTokenCount - totalTokenCountFilesOnly - codeMapTokenCount - gitDiffTokenCount - treeTokens
        if otherTokens > 0 {
            parts.append("• Other: \(String(format: "%.2fk", Double(otherTokens) / 1000.0))")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Cleanup

    deinit {
        tokenUpdateDebounceTask?.cancel()
        tokenUpdateDebounceTask = nil
        updateTokenCountTask?.cancel()
        updateTokenCountTask = nil
        cancellables.removeAll()
    }

    // MARK: - File System Topology

    private func handleFileSystemTopologyChanged() {
        // Immediately clear caches used by UI previews so we don't show stale data
        cachedFileAPIs = []
        scannedLanguages = []
        codeMapContent = ""
        fileTreeContent = ""
        codeMapFileCount = 0
        codeMapTokenCount = 0
        lastFileTreeTokens = 0

        // Mark heavy recomputation so totals and tree are rebuilt by the dirty debounce scheduler.
        let heavy: DirtyKind = [.selection, .fileTree, .codeMap, .settings]
        markDirty(heavy)
    }
}
