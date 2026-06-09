import Combine
import Foundation
import RepoPromptCore
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

    /// Accepted projection state used by light, incremental recomputation.
    private var didComputeBaseline: Bool = false
    private var acceptedSelectionProjection: WorkspaceSelectionProjection?
    private var acceptedWorkspaceTokenViews: TokenProjectionService.WorkspaceViews?
    private var publishedWorkspaceTokenProjection: TokenProjection?
    private var acceptedHasSelectedArtifacts: Bool = false
    private var lastFileTreeTokens: Int = 0
    private var lastGitDiffText: String?

    // MARK: - Private Properties

    private static let tokenUpdateDebounceNanoseconds: UInt64 = 500_000_000

    typealias ProjectionAdapterFactory = @MainActor (WorkspaceFileContextStore) -> WorkspacePromptProjectionAdapter
    typealias AccountingOperation = (
        PromptContextAccountingRequest,
        WorkspaceFileContextStore,
        WorkspaceFileContextCapture
    ) async throws -> PromptContextAccountingResult
    typealias LightProjectionOperation = (
        WorkspaceSelectionProjection,
        TokenProjection.Source,
        TokenProjectionService.WorkspaceNonFileComponents
    ) async throws -> TokenProjectionService.WorkspaceViews

    private let promptContextAccountingService = PromptContextAccountingService()
    private let projectionAdapterFactory: ProjectionAdapterFactory
    private let accountingOperation: AccountingOperation?
    private let lightProjectionOperation: LightProjectionOperation
    private var tokenUpdateDebounceTask: Task<Void, Never>?
    private var updateTokenCountTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var isTokenCountSchedulerActive = false
    private var isImmediateRecountInProgress = false
    private var tokenCountSchedulerGeneration: UInt64 = 0
    private var inputRevision: UInt64 = 0
    private var nextRecountRunID: UInt64 = 0
    private var activeRecountRunID: UInt64?
    private var selectionObservationRevision: UInt64 = 0
    private var lastObservedSelectionObservationRevision: UInt64 = 0
    private var automaticRecountSuspendDepth: Int = 0
    private var heavyRecoveryAttempted = false

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

    init(
        projectionAdapterFactory: @escaping ProjectionAdapterFactory = { store in
            WorkspacePromptProjectionAdapter(store: store)
        },
        accountingOperation: AccountingOperation? = nil,
        lightProjectionOperation: @escaping LightProjectionOperation = { selection, source, nonFile in
            TokenProjectionService.workspaceComponentEstimates(
                from: selection,
                source: source,
                nonFile: nonFile
            )
        }
    ) {
        self.projectionAdapterFactory = projectionAdapterFactory
        self.accountingOperation = accountingOperation
        self.lightProjectionOperation = lightProjectionOperation
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
        guard !kind.isEmpty else { return }
        inputRevision &+= 1
        pendingDirty.formUnion(kind)

        if !kind.intersection(heavyDirtyKinds).isEmpty {
            heavyRecoveryAttempted = false
            invalidateAcceptedSelectionProjection()
        }

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

    #if DEBUG
        func debugTokenRecountStateFields() -> [String: String] {
            [
                "pendingDirtyRaw": "\(pendingDirty.rawValue)",
                "schedulerActive": "\(isTokenCountSchedulerActive)",
                "suspendDepth": "\(automaticRecountSuspendDepth)",
                "debouncePending": "\(tokenUpdateDebounceTask != nil)",
                "updatePending": "\(updateTokenCountTask != nil)",
                "immediateInProgress": "\(isImmediateRecountInProgress)",
                "didComputeBaseline": "\(didComputeBaseline)",
                "inputRevision": "\(inputRevision)",
                "activeRunID": activeRecountRunID.map(String.init) ?? "none",
                "acceptedSelection": "\(acceptedSelectionProjection != nil)",
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

        func processPendingRecountForTesting() async {
            let kinds = pendingDirty
            pendingDirty = []
            if !kinds.intersection(heavyDirtyKinds).isEmpty {
                await performTokenCountOffMainThread()
            } else {
                await recalculateLight(kinds: kinds)
            }
        }

        var hasAcceptedSelectionProjectionForTesting: Bool {
            acceptedSelectionProjection != nil
        }

        var publishedTokenProjectionForTesting: TokenProjection? {
            publishedWorkspaceTokenProjection
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

    private struct RecountRun {
        let id: UInt64
        let inputRevision: UInt64
    }

    private func beginRecountRun() -> RecountRun {
        nextRecountRunID &+= 1
        let run = RecountRun(id: nextRecountRunID, inputRevision: inputRevision)
        activeRecountRunID = run.id
        return run
    }

    private func isCurrent(_ run: RecountRun) -> Bool {
        !Task.isCancelled
            && activeRecountRunID == run.id
            && inputRevision == run.inputRevision
    }

    private func finishRecountRun(_ run: RecountRun) {
        if activeRecountRunID == run.id {
            activeRecountRunID = nil
        }
    }

    private func invalidateAcceptedSelectionProjection() {
        acceptedSelectionProjection = nil
        acceptedWorkspaceTokenViews = nil
        acceptedHasSelectedArtifacts = false
        didComputeBaseline = false
    }

    private func selectedTokenProjection(
        from views: TokenProjectionService.WorkspaceViews
    ) -> TokenProjection {
        views.userConfigured ?? views.normalized
    }

    private func selectedIncludedFiles(
        from selection: WorkspaceSelectionProjection
    ) -> [WorkspaceSelectionProjection.IncludedFile] {
        selection.alternate?.includedFiles ?? selection.normalizedFiles
    }

    private func retryHeavyImmediatelyAfterRecoverableError(
        _ error: Error,
        run: RecountRun
    ) async -> Bool {
        guard isCurrent(run), !(error is CancellationError), !Task.isCancelled else { return false }
        guard isRecoverableHeavyError(error), !heavyRecoveryAttempted else { return false }
        heavyRecoveryAttempted = true
        await performTokenCountOffMainThread(isRetry: true)
        return true
    }

    private func isRecoverableHeavyError(_ error: Error) -> Bool {
        if let adapterError = error as? WorkspacePromptProjectionAdapter.Error {
            switch adapterError {
            case .missingTokenFacts, .unusedTokenFacts, .projectionProvenanceMismatch:
                return true
            case .missingSelectionProjection, .missingTokenProjection:
                return false
            }
        }
        if let projectionError = error as? WorkspaceContextProjectionError {
            switch projectionError {
            case .captureProvenanceMismatch,
                 .recordAssociationMismatch,
                 .codemapAssociationMismatch,
                 .materializationProvenanceMismatch,
                 .missingOccurrenceIDs,
                 .missingTokenFacts:
                return true
            case .duplicateRootID,
                 .rootAssociationMismatch,
                 .duplicateCodemapFileID,
                 .duplicateOccurrenceID,
                 .unexpectedOccurrenceIDs,
                 .invalidTokenFacts:
                return false
            }
        }
        if error is PromptContextAccountingError {
            return true
        }
        return true
    }

    private func allStoreFileRecords(from store: WorkspaceFileContextStore) async -> [WorkspaceFileRecord] {
        let roots = await store.roots()
        var records: [WorkspaceFileRecord] = []
        for root in roots {
            await records.append(contentsOf: store.files(inRoot: root.id))
        }
        return records
    }

    // MARK: - Token Calculation

    /// Heavy path (rebuild baseline and everything else).
    private func performTokenCountOffMainThread(isRetry: Bool = false) async {
        if !isRetry {
            heavyRecoveryAttempted = false
        }
        let run = beginRecountRun()
        defer { finishRecountRun(run) }
        #if DEBUG
            let calculateStartMS = PromptTokenRecountDiagnostics.start()
            var beginFields = debugTokenRecountStateFields()
            beginFields["runID"] = "\(run.id)"
            beginFields["runInputRevision"] = "\(run.inputRevision)"
            PromptTokenRecountDiagnostics.event("tokenRecount.calculate.begin", fields: beginFields)
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
        let selectionAtStart = currentStoredSelection(includeFiles: true)
        #if DEBUG
            var selectionFields = debugSelectionFields(selectionAtStart)
            selectionFields["includeFiles"] = "\(includeFiles)"
            PromptTokenRecountDiagnostics.event("tokenRecount.calculate.selectionSnapshot", fields: selectionFields)
        #endif

        let promptText = copySnapshot.includeUserPrompt ? promptSource : ""
        let selectedInstructionsText = copySnapshot.includeMetaPrompts ? instructionsSource : ""
        let duplicatePromptAtTop = copySnapshot.includeUserPrompt
            ? copySnapshot.duplicateUserInstructionsAtTop
            : false
        let store = fileManager.workspaceFileContextStore

        let allFileRecords = await allStoreFileRecords(from: store)
        guard isCurrent(run) else { return }
        let storeFileAPIs = await store.allCodemapFileAPIs()
        guard isCurrent(run) else { return }

        let detectedExts = allFileRecords.map { (($0.name as NSString).pathExtension).lowercased() }
        let detectedLanguages = Set(detectedExts.compactMap { SyntaxManager.shared.extensionToLanguage[$0] })
        let normalizedCodeMapUsage: CodeMapUsage = settings.codeMapsGloballyDisabled ? .none : .auto
        let configuredCodeMapUsage: CodeMapUsage = settings.codeMapsGloballyDisabled
            ? .none
            : copySnapshot.codeMapUsage
        let effectiveFileTreeOption: FileTreeOption = copySnapshot.includeFileTree
            ? copySnapshot.fileTreeMode
            : .none
        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.context",
                fields: [
                    "includeFiles": "\(includeFiles)",
                    "includeFileTree": "\(copySnapshot.includeFileTree)",
                    "fileTreeMode": "\(effectiveFileTreeOption)",
                    "normalizedCodeMapUsage": "\(normalizedCodeMapUsage)",
                    "configuredCodeMapUsage": "\(configuredCodeMapUsage)",
                    "gitInclusion": "\(copySnapshot.gitInclusion)"
                ]
            )
        #endif

        let alternatePolicy = WorkspaceSelectionProjectionRequest.AlternatePolicy(
            includeFiles: includeFiles,
            codeMapUsage: configuredCodeMapUsage
        )
        let fileTreeRequest = WorkspaceFileTreeSnapshotRequest(
            mode: WorkspaceFileTreeSnapshotMode(fileTreeOption: effectiveFileTreeOption),
            filePathDisplay: settings.filePathDisplayOption,
            onlyIncludeRootsWithSelectedFiles: settings.onlyIncludeRootsWithSelectedFiles,
            includeLegend: copySnapshot.includeFileTree,
            showCodeMapMarkers: copySnapshot.includeFileTree && !settings.codeMapsGloballyDisabled,
            rootScope: .allLoaded
        )
        let adapter = projectionAdapterFactory(store)
        let workspaceCapture: WorkspaceFileContextCapture
        do {
            workspaceCapture = try await adapter.captureWorkspaceContext(
                selection: selectionAtStart,
                codeMapUsage: normalizedCodeMapUsage,
                filePathDisplay: settings.filePathDisplayOption,
                alternatePolicy: alternatePolicy,
                fileTreeRequest: fileTreeRequest
            )
        } catch {
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.calculate.error",
                    fields: [
                        "reason": "capture",
                        "error": "\(error)",
                        "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            _ = await retryHeavyImmediatelyAfterRecoverableError(error, run: run)
            return
        }
        guard isCurrent(run) else { return }

        let fileTreeInput: TokenCalculationFileTreeInput = if copySnapshot.includeFileTree,
                                                              effectiveFileTreeOption != .none
        {
            .snapshot(workspaceCapture.fileTree)
        } else {
            .none
        }

        let accountingRequest = PromptContextAccountingRequest(
            selection: selectionAtStart,
            promptText: promptText,
            selectedInstructionsText: selectedInstructionsText,
            duplicateUserInstructionsAtTop: duplicatePromptAtTop,
            fileTree: fileTreeInput,
            codeMapUsage: normalizedCodeMapUsage,
            filePathDisplay: settings.filePathDisplayOption,
            rootScope: .allLoaded,
            pathLocateProfile: .uiAssisted
        )
        let accountingResult: PromptContextAccountingResult
        do {
            if let accountingOperation {
                accountingResult = try await accountingOperation(
                    accountingRequest,
                    store,
                    workspaceCapture
                )
            } else {
                accountingResult = try await promptContextAccountingService.calculatePromptStats(
                    request: accountingRequest,
                    store: store,
                    capture: workspaceCapture
                )
            }
            guard accountingResult.captureProvenance == workspaceCapture.provenance else {
                throw WorkspacePromptProjectionAdapter.Error.projectionProvenanceMismatch
            }
        } catch {
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.calculate.error",
                    fields: [
                        "reason": "accounting",
                        "error": "\(error)",
                        "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            _ = await retryHeavyImmediatelyAfterRecoverableError(error, run: run)
            return
        }
        guard isCurrent(run) else { return }

        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.calculate.accounting.end",
                fields: [
                    "resolvedEntries": "\(accountingResult.resolvedEntries.count)",
                    "promptEntries": "\(accountingResult.promptFileEntrySnapshots.count)",
                    "missingPaths": "\(accountingResult.missingPaths.count)",
                    "invalidPaths": "\(accountingResult.invalidPaths.count)",
                    "codemapsUsed": "\(accountingResult.codemapSnapshotsUsed.count)"
                ]
            )
        #endif

        let detailResult = accountingResult.tokenResult
        let resolvedFileEntries = includeFiles ? accountingResult.resolvedEntries : []
        let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(resolvedFileEntries)
        let hasSelectedArtifacts = !diffEntries.isEmpty

        let gitDiffText: String? = if hasSelectedArtifacts || copySnapshot.gitInclusion == .none || gitViewModel == nil {
            nil
        } else {
            switch copySnapshot.gitInclusion {
            case .none:
                nil
            case .selected:
                await gitViewModel?.getDiffUsing(inclusionMode: .selectedFiles)
            case .complete:
                await gitViewModel?.getDiffUsing(inclusionMode: .all)
            }
        }
        guard isCurrent(run) else { return }

        let componentBreakdown = TokenCalculationService.calculateComponentBreakdown(
            promptText: promptText,
            selectedInstructionsText: selectedInstructionsText,
            fileTreeText: detailResult.fileTreeContent,
            gitDiffText: gitDiffText,
            metadataText: nil,
            duplicateUserInstructionsAtTop: duplicatePromptAtTop
        )
        let adapterProjection: WorkspacePromptProjectionAdapter.TokenAwareProjection
        do {
            adapterProjection = try await adapter.projectTokens(
                capture: workspaceCapture,
                codeMapUsage: normalizedCodeMapUsage,
                filePathDisplay: settings.filePathDisplayOption,
                alternatePolicy: alternatePolicy,
                resolvedEntries: accountingResult.resolvedEntries,
                promptFileEntrySnapshots: accountingResult.promptFileEntrySnapshots,
                tokenProjectionInput: .activeLive(.init(
                    reportedTotal: detailResult.totalTokenCount + componentBreakdown.gitDiff,
                    prompt: componentBreakdown.promptDisplay,
                    fileTree: componentBreakdown.fileTree,
                    meta: componentBreakdown.instructions,
                    git: componentBreakdown.gitDiff,
                    requestedFileTreeEstimate: detailResult.fileTreeTokenCountRaw
                ))
            )
        } catch {
            #if DEBUG
                PromptTokenRecountDiagnostics.event(
                    "tokenRecount.calculate.error",
                    fields: [
                        "reason": "projection",
                        "error": "\(error)",
                        "duration": calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            _ = await retryHeavyImmediatelyAfterRecoverableError(error, run: run)
            return
        }
        guard isCurrent(run) else { return }

        if currentStoredSelection(includeFiles: true) != selectionAtStart {
            markDirty(.selection)
            return
        }
        guard isCurrent(run) else { return }

        let workspaceViews = TokenProjectionService.WorkspaceViews(
            normalized: adapterProjection.tokens.normalized,
            userConfigured: adapterProjection.tokens.userConfigured
        )
        let selectedProjection = selectedTokenProjection(from: workspaceViews)
        let components = selectedProjection.components
        let filesContentTokens = components.filesContent ?? 0
        let codemapTokens = components.codemaps ?? 0
        let gitTokens = components.git ?? 0
        let fileTreeTokens = components.fileTree ?? 0
        let totalTokens = selectedProjection.total
        let totalTokenString = String(format: "%.2fk", Double(totalTokens) / 1000.0)
        let filesContentString = String(format: "%.2fk", Double(filesContentTokens) / 1000.0)
        let gitTokenString = String(format: "%.2fk", Double(gitTokens) / 1000.0)
        let projectionDetails = projectionDetailData(
            selection: adapterProjection.selection,
            totalFileTokens: components.files ?? 0
        )
        let selectedCharCount = includeFiles
            ? detailResult.charCount
            : promptText.count
            + (duplicatePromptAtTop ? promptText.count : 0)
            + selectedInstructionsText.count

        #if DEBUG
            PromptTokenRecountDiagnostics.event(
                "tokenRecount.publish.begin",
                fields: [
                    "runID": "\(run.id)",
                    "resolvedEntries": "\(accountingResult.resolvedEntries.count)",
                    "fileTokenInfos": "\(projectionDetails.fileTokenInfo.count)",
                    "folderTokenInfos": "\(projectionDetails.folderTokenInfo.count)",
                    "totalTokens": "\(totalTokens)",
                    "fileTokens": "\(filesContentTokens)",
                    "codeMapTokens": "\(codemapTokens)",
                    "fileTreeTokens": "\(fileTreeTokens)"
                ]
            )
        #endif

        cachedFileAPIs = storeFileAPIs
        scannedLanguages = detectedLanguages
        fileTokenInfo = projectionDetails.fileTokenInfo
        folderTokenInfo = projectionDetails.folderTokenInfo
        fileTreeContent = detailResult.fileTreeContent
        codeMapContent = projectionDetails.codeMapContent
        lastFileTreeTokens = fileTreeTokens
        charCount = selectedCharCount
        totalTokenCount = totalTokens
        tokenCount = totalTokenString
        tokenCountFilesOnly = filesContentString
        totalTokenCountFilesOnly = filesContentTokens
        codeMapFileCount = projectionDetails.codeMapFileCount
        codeMapTokenCount = codemapTokens
        gitDiffTokenCount = gitTokens
        gitDiffTokenCountString = gitTokenString
        lastGitDiffText = gitDiffText
        copyContextTotalTokens = totalTokens
        copyContextTokenCountString = totalTokenString
        acceptedSelectionProjection = adapterProjection.selection
        acceptedWorkspaceTokenViews = workspaceViews
        publishedWorkspaceTokenProjection = selectedProjection
        acceptedHasSelectedArtifacts = hasSelectedArtifacts
        didComputeBaseline = true
        heavyRecoveryAttempted = false

        tokenCalculationCompletedPublisher.send()
        #if DEBUG
            var endFields = debugTokenRecountStateFields()
            endFields["runID"] = "\(run.id)"
            endFields["duration"] = calculateStartMS.map { PromptTokenRecountDiagnostics.formatElapsedMS(since: $0) } ?? "notMeasured"
            PromptTokenRecountDiagnostics.event("tokenRecount.calculate.end", fields: endFields)
        #endif
    }

    private struct ProjectionDetailData {
        let fileTokenInfo: [UUID: TokenInfo]
        let folderTokenInfo: [String: TokenInfo]
        let codeMapFileCount: Int
        let codeMapContent: String
    }

    private func projectionDetailData(
        selection: WorkspaceSelectionProjection,
        totalFileTokens: Int
    ) -> ProjectionDetailData {
        let includedFiles = selectedIncludedFiles(from: selection)
        var fileCounts: [UUID: Int] = [:]
        var fullCounts: [UUID: Int] = [:]
        var codemapCounts: [UUID: Int] = [:]
        var folderTokens: [String: Int] = [:]
        var codemapContents: [String] = []
        var codeMapFileCount = 0

        for file in includedFiles {
            fileCounts[file.file.id, default: 0] += file.tokens
            if let fullTokens = file.fullTokens {
                if let existing = fullCounts[file.file.id] {
                    assert(existing == fullTokens, "Duplicate occurrences disagree on full token facts")
                }
                fullCounts[file.file.id] = max(fullCounts[file.file.id] ?? 0, fullTokens)
            }
            codemapCounts[file.file.id] = max(codemapCounts[file.file.id] ?? 0, file.codemapTokens)

            if file.mode == .codemap {
                codeMapFileCount += 1
                if let content = file.codemapContent, !content.isEmpty {
                    codemapContents.append(content)
                }
            }

            let folderPath = (file.metadata.pathWithinRoot as NSString).deletingLastPathComponent
            folderTokens[folderPath == "." ? "" : folderPath, default: 0] += file.tokens
        }

        assert(fileCounts.values.reduce(0, +) == totalFileTokens, "Projection details must match aggregate file tokens")
        var mappedFiles: [UUID: TokenInfo] = [:]
        for (fileID, count) in fileCounts {
            mappedFiles[fileID] = TokenInfo(
                count: count,
                fullCount: fullCounts[fileID] ?? 0,
                codemapCount: codemapCounts[fileID] ?? 0,
                totalTokens: totalFileTokens
            )
        }

        let mappedFolders = folderTokens.reduce(into: [String: TokenInfo]()) { result, item in
            result[item.key] = TokenInfo(count: item.value, totalTokens: totalFileTokens)
        }
        return ProjectionDetailData(
            fileTokenInfo: mappedFiles,
            folderTokenInfo: mappedFolders,
            codeMapFileCount: codeMapFileCount,
            codeMapContent: TokenCalculationService.composeCodemapContent(codemapContents)
        )
    }

    /// Light path (prompt text and/or meta instructions and/or git diff only).
    private func recalculateLight(kinds: DirtyKind) async {
        guard didComputeBaseline,
              let acceptedSelectionProjection,
              let acceptedViews = acceptedWorkspaceTokenViews,
              let promptSource = getPromptText?(),
              let instructionsSource = getSelectedInstructionsText?()
        else {
            await performTokenCountOffMainThread()
            return
        }

        let run = beginRecountRun()
        defer { finishRecountRun(run) }
        let copySnapshot = resolveCopyContextSnapshot()
        let promptText = copySnapshot.includeUserPrompt ? promptSource : ""
        let selectedInstructionsText = copySnapshot.includeMetaPrompts ? instructionsSource : ""
        let duplicatePrompt = copySnapshot.includeUserPrompt
            ? copySnapshot.duplicateUserInstructionsAtTop
            : false

        var gitDiffText = lastGitDiffText
        if kinds.contains(.gitDiff) {
            if acceptedHasSelectedArtifacts || copySnapshot.gitInclusion == .none || gitViewModel == nil {
                gitDiffText = nil
            } else {
                switch copySnapshot.gitInclusion {
                case .none:
                    gitDiffText = nil
                case .selected:
                    gitDiffText = await gitViewModel?.getDiffUsing(inclusionMode: .selectedFiles)
                case .complete:
                    gitDiffText = await gitViewModel?.getDiffUsing(inclusionMode: .all)
                }
            }
        }
        guard isCurrent(run) else { return }

        let componentBreakdown = TokenCalculationService.calculateComponentBreakdown(
            promptText: promptText,
            selectedInstructionsText: selectedInstructionsText,
            fileTreeText: "",
            gitDiffText: gitDiffText,
            metadataText: nil,
            duplicateUserInstructionsAtTop: duplicatePrompt
        )
        let nonFile = TokenProjectionService.WorkspaceNonFileComponents(
            prompt: componentBreakdown.promptDisplay,
            fileTree: acceptedViews.normalized.components.fileTree ?? 0,
            meta: componentBreakdown.instructions,
            git: componentBreakdown.gitDiff,
            other: acceptedViews.normalized.components.other ?? 0
        )
        let workspaceViews: TokenProjectionService.WorkspaceViews
        do {
            workspaceViews = try await lightProjectionOperation(
                acceptedSelectionProjection,
                .virtualRecomputed,
                nonFile
            )
        } catch {
            return
        }
        let selectedProjection = selectedTokenProjection(from: workspaceViews)
        let gitTokens = selectedProjection.components.git ?? 0
        let totalTokens = selectedProjection.total
        let tokenString = String(format: "%.2fk", Double(totalTokens) / 1000.0)
        guard isCurrent(run) else { return }

        totalTokenCount = totalTokens
        tokenCount = tokenString
        copyContextTotalTokens = totalTokens
        copyContextTokenCountString = tokenString
        gitDiffTokenCount = gitTokens
        gitDiffTokenCountString = String(format: "%.2fk", Double(gitTokens) / 1000.0)
        lastGitDiffText = gitDiffText
        acceptedWorkspaceTokenViews = workspaceViews
        publishedWorkspaceTokenProjection = selectedProjection

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
        if let projection = publishedWorkspaceTokenProjection {
            return TokenBreakdown(
                total: projection.total,
                files: projection.components.files ?? 0,
                prompt: projection.components.prompt ?? 0,
                meta: projection.components.meta ?? 0,
                fileTree: projection.components.fileTree ?? 0,
                git: projection.components.git ?? 0,
                other: projection.components.other ?? 0
            )
        }

        let promptSource = getPromptText?() ?? ""
        let instructionsSource = getSelectedInstructionsText?() ?? ""
        let promptTokens = promptSource.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: promptSource)
        let metaTokens = instructionsSource.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: instructionsSource)
        let fileTreeTokens = fileTreeContent.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: fileTreeContent)
        let filesTokens = totalFileTokensDisplay
        let total = promptTokens + filesTokens + metaTokens + fileTreeTokens
        return TokenBreakdown(
            total: total,
            files: filesTokens,
            prompt: promptTokens,
            meta: metaTokens,
            fileTree: fileTreeTokens,
            git: 0,
            other: 0
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
