import Foundation
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptInstrumentation
import RepoPromptSettingsCore
import RepoPromptWorkspaceCore

package enum FilePathDisplay: String, CaseIterable {
    case full = "Full"
    case relative = "Relative"
}

#if DEBUG
    package enum WorkspacePreparationPhase: String, CaseIterable, Equatable {
        case scopeResolution = "scope_resolution"
        case setFlagsTotal = "set_flags_total"
        case loadedRootIngressFence = "loaded_root_ingress_fence"
        case loadedRootPolicySnapshot = "loaded_root_policy_snapshot"
        case discoveryObservation = "discovery_observation"
        case discoveryAuthorityCapture = "discovery_authority_capture"
        case replacementObservation = "replacement_observation"
        case collectionFence = "collection_fence"
        case capturedAuthorityCapture = "captured_authority_capture"
        case capturedObservationValidation = "captured_observation_validation"
        case authorityMetadataGit = "authority_metadata_git"
        case prefixControlCacheLookup = "prefix_control_cache_lookup"
        case prefixControlScan = "prefix_control_scan"
        case prefixControlCacheAdmit = "prefix_control_cache_admit"
        case treeInventorySpool = "tree_inventory_spool"
        case catalogManifestBuild = "catalog_manifest_build"
        case authorityInstall = "authority_install"
        case snapshotMaterialization = "snapshot_materialization"
        case admissionPrepare = "admission_prepare"
        case preparedAdmissionCurrentness = "prepared_admission_currentness"
        case admissionCommit = "admission_commit"
        case committedAdmissionCurrentness = "committed_admission_currentness"
        case finalLoadedRootCurrentness = "final_loaded_root_currentness"
    }

    package enum WorkspacePreparationCounter: String, CaseIterable, Equatable {
        case authorityCaptures = "authority_captures"
        case gitCommandCount = "git_command_count"
        case gitQueueMicroseconds = "git_queue_us"
        case gitDurationMicroseconds = "git_duration_us"
        case prefixCacheHits = "prefix_cache_hits"
        case prefixCacheMisses = "prefix_cache_misses"
        case prefixCacheInvalidations = "prefix_cache_invalidations"
        case prefixCacheAdmissions = "prefix_cache_admissions"
        case prefixCacheEvictions = "prefix_cache_evictions"
        case prefixCacheBypasses = "prefix_cache_bypasses"
        case prefixCacheCoalesces = "prefix_cache_coalesces"
        case prefixScanCount = "prefix_scan_count"
        case enumeratedCandidates = "enumerated_candidates"
        case enumeratedDirectories = "enumerated_directories"
        case explicitlyPrunedDirectories = "explicitly_pruned_directories"
        case controlRecordCount = "control_record_count"
        case treeRecords = "tree_records"
        case treeSpoolBytes = "tree_spool_bytes"
        case inventoryRecords = "inventory_records"
        case catalogBatches = "catalog_batches"
        case catalogRegularPaths = "catalog_regular_paths"
        case snapshotSearchablePaths = "snapshot_searchable_paths"
    }

#endif

#if DEBUG
    package enum WorkspaceReceiptMatchState: String, Equatable {
        case notEvaluated
        case match
        case mismatch
    }

    package enum WorkspaceReceiptFinalObservation: Equatable {
        case eligible
        case disabled
        case fallback(WorkspaceRootSeedFallbackReason)
    }

    package struct WorkspaceReceiptProjectionDecision: Equatable {
        package var suppliedHintCount = 0
        package var matchedHintCount = 0
        package var allHintKeysMatchedBindings: Bool?
        package var validationFallback: WorkspaceRootSeedFallbackReason?

        package init() {}
    }

    package struct WorkspaceReceiptConsumptionDecision: Equatable {
        package var ownerGenerationMatch: WorkspaceReceiptMatchState = .notEvaluated
        package var hintSessionMatch: WorkspaceReceiptMatchState = .notEvaluated
        package var hintCorrelationMatch: WorkspaceReceiptMatchState = .notEvaluated
        package var hintOwnerMatch: WorkspaceReceiptMatchState = .notEvaluated
        package var ownershipReused: Bool?
        package var initialHintObservation: WorkspaceReceiptFinalObservation?
        package var pendingSeededPreparationResult: WorkspaceReceiptFinalObservation?
        package var fullCrawlPerformed: Bool?
        package var finalObservation: WorkspaceReceiptFinalObservation?
        package var selectedRoute: WorkspaceRootStartupRoute?

        package init() {}
    }

    package struct WorkspaceBenchmarkMetricTag: Hashable {
        package let correlationID: UUID
        package let contextID: UUID
        package let agentSessionID: UUID
        package let logicalRootID: UUID
        package let repositoryID: String
        package let destinationID: String

        package init(
            correlationID: UUID,
            contextID: UUID,
            agentSessionID: UUID,
            logicalRootID: UUID,
            repositoryID: String,
            destinationID: String
        ) {
            self.correlationID = correlationID
            self.contextID = contextID
            self.agentSessionID = agentSessionID
            self.logicalRootID = logicalRootID
            self.repositoryID = repositoryID
            self.destinationID = destinationID
        }
    }

    package enum WorkspaceBenchmarkPlannerPhase: String, CaseIterable {
        case targetNamespace
        case treeEvidence
        case indexEvidence
        case statusEvidence
        case reconcile
    }

    package enum WorkspaceBenchmarkMarkerPublicationSource: String, Equatable {
        case publishedUpdate
        case warmReplay
    }

#endif

package typealias WorkspaceSessionWorktreeBinding = RepoPromptDomainRuntime.AgentSessionWorktreeBinding

#if DEBUG
    package enum WorkspacePreparationReason: String, CaseIterable, Equatable {
        case absent
        case bypassed
        case rootIdentityChanged = "root_identity_changed"
        case authorityGenerationChanged = "authority_generation_changed"
        case watermarkAdvanced = "watermark_advanced"
        case coverageLost = "coverage_lost"
        case monitorUnavailable = "monitor_unavailable"
        case controlOrTopologyEvent = "control_or_topology_event"
        case monitorGap = "monitor_gap"
        case replacement
        case capacityEviction = "capacity_eviction"
        case staleCurrentness = "stale_currentness"
        case fallback
        case failure
        case cancellation
    }

    package protocol WorkspacePreparationSpan: Sendable {
        func end()
    }

    package protocol WorkspacePreparationRecording: Sendable {
        func beginPhase(_ phase: WorkspacePreparationPhase) -> any WorkspacePreparationSpan
        func increment(_ counter: WorkspacePreparationCounter, by amount: UInt64)
        func recordPreparationReason(_ reason: WorkspacePreparationReason)
    }

    extension WorkspacePreparationRecording {
        func increment(_ counter: WorkspacePreparationCounter) {
            increment(counter, by: 1)
        }
    }

    package protocol WorkspacePreparationRecorderProviding: Sendable {
        func currentRecorder() -> (any WorkspacePreparationRecording)?
    }

    package enum WorkspacePreparationInstrumentation {
        private final class Storage: @unchecked Sendable {
            let lock = NSLock()
            var provider: (any WorkspacePreparationRecorderProviding)?
        }

        private static let storage = Storage()

        package static func install(_ provider: any WorkspacePreparationRecorderProviding) {
            storage.lock.lock()
            storage.provider = provider
            storage.lock.unlock()
        }

        static var currentRecorder: (any WorkspacePreparationRecording)? {
            storage.lock.lock()
            let provider = storage.provider
            storage.lock.unlock()
            return provider?.currentRecorder()
        }
    }

    package protocol WorkspaceApplyEditsRebaseProbeRecording: Sendable {
        func recordPublisherIngress(rootID: UUID, source: FileSystemDeltaPublicationSource, deltas: [FileSystemDelta])
        func recordStoreModification(rootID: UUID, fileID: UUID, generation: UInt64)
        func recordAppliedIndexModification(rootID: UUID, fileIDs: [UUID], generation: UInt64)
    }

    package enum WorkspaceApplyEditsRebaseProbeHooks {
        private final class Storage: @unchecked Sendable {
            let lock = NSLock()
            var recorder: (any WorkspaceApplyEditsRebaseProbeRecording)?
        }

        private static let storage = Storage()

        package static func install(_ recorder: any WorkspaceApplyEditsRebaseProbeRecording) {
            storage.lock.lock()
            storage.recorder = recorder
            storage.lock.unlock()
        }

        private static func currentRecorder() -> (any WorkspaceApplyEditsRebaseProbeRecording)? {
            storage.lock.lock()
            defer { storage.lock.unlock() }
            return storage.recorder
        }

        static func recordPublisherIngress(rootID: UUID, source: FileSystemDeltaPublicationSource, deltas: [FileSystemDelta]) {
            currentRecorder()?.recordPublisherIngress(rootID: rootID, source: source, deltas: deltas)
        }

        static func recordStoreModification(rootID: UUID, fileID: UUID, generation: UInt64) {
            currentRecorder()?.recordStoreModification(rootID: rootID, fileID: fileID, generation: generation)
        }

        static func recordAppliedIndexModification(rootID: UUID, fileIDs: [UUID], generation: UInt64) {
            currentRecorder()?.recordAppliedIndexModification(rootID: rootID, fileIDs: fileIDs, generation: generation)
        }
    }

    package protocol WorkspaceRootLoadFieldProviding: Sendable {
        func rootRecordCreatedFields(forPath path: String) -> [String: String]
        func firstPreparedChunkFields(forPath path: String) -> [String: String]
    }

    package enum WorkspaceRootLoadFieldHooks {
        private final class Storage: @unchecked Sendable {
            let lock = NSLock()
            var provider: (any WorkspaceRootLoadFieldProviding)?
        }

        private static let storage = Storage()

        package static func install(_ provider: any WorkspaceRootLoadFieldProviding) {
            storage.lock.lock()
            storage.provider = provider
            storage.lock.unlock()
        }

        private static func currentProvider() -> (any WorkspaceRootLoadFieldProviding)? {
            storage.lock.lock()
            defer { storage.lock.unlock() }
            return storage.provider
        }

        static func rootRecordCreatedFields(forPath path: String) -> [String: String] {
            currentProvider()?.rootRecordCreatedFields(forPath: path) ?? [:]
        }

        static func firstPreparedChunkFields(forPath path: String) -> [String: String] {
            currentProvider()?.firstPreparedChunkFields(forPath: path) ?? [:]
        }
    }
#endif

package enum WorkspaceSessionBindingFingerprint {
    package static func make(_ bindings: [WorkspaceSessionWorktreeBinding]) -> String {
        bindings
            .map { binding in
                [
                    binding.repositoryID,
                    binding.repoKey,
                    StandardizedPath.absolute((binding.logicalRootPath as NSString).expandingTildeInPath),
                    binding.worktreeID,
                    StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath),
                    binding.commonGitDir.map(StandardizedPath.absolute) ?? "",
                    binding.isMainWorktree.map { String($0) } ?? "",
                    binding.branch ?? "",
                    binding.head ?? ""
                ].joined(separator: "\u{1F}")
            }
            .sorted()
            .joined(separator: "\u{1E}")
    }
}

package enum WorkspaceLookupContextResolutionError: LocalizedError {
    case unavailableProjection
    case unknownBindingState

    package var errorDescription: String? {
        switch self {
        case .unavailableProjection:
            "The Agent session worktree projection is unavailable. The operation stopped rather than falling back to the canonical checkout."
        case .unknownBindingState:
            "The Agent session worktree bindings are not hydrated or are unavailable. The operation stopped rather than falling back to the canonical checkout."
        }
    }
}

package struct WorkspaceSelectedFilesDiagnostics {
    package let perfRecorder: any AgentModePerfRecording

    package init(perfRecorder: any AgentModePerfRecording) {
        self.perfRecorder = perfRecorder
    }

    package func timestampMSIfEnabled() -> Double? {
        #if DEBUG
            perfRecorder.timestampMSIfEnabled()
        #else
            nil
        #endif
    }

    package func elapsedFields(since startMS: Double?) -> [String: String] {
        #if DEBUG
            guard let startMS else { return [:] }
            return ["duration": perfRecorder.formatElapsedMS(since: startMS)]
        #else
            [:]
        #endif
    }

    package func event(
        _ name: String,
        fields: [String: String] = [:],
        includeStack: Bool = false
    ) {
        #if DEBUG
            guard perfRecorder.isEnabled else { return }
            var fields = fields
            if includeStack {
                fields["stack"] = Self.compactCallStack()
            }
            perfRecorder.event("selectedFiles.\(name)", fields: fields)
        #endif
    }

    package func durationEvent(
        _ name: String,
        startMS: Double?,
        fields: [String: String] = [:]
    ) {
        #if DEBUG
            perfRecorder.durationEvent("selectedFiles.\(name)", startMS: startMS, fields: fields)
        #endif
    }

    package static func shortID(_ id: UUID?) -> String {
        #if DEBUG
            NoopAgentModePerfRecorder().shortID(id)
        #else
            "nil"
        #endif
    }

    package static func selectionFields(_ selection: StoredSelection) -> [String: String] {
        #if DEBUG
            let nonEmptySlices = selection.slices.filter { !$0.value.isEmpty }
            let sliceRanges = nonEmptySlices.values.reduce(0) { $0 + $1.count }
            return [
                "selectedPaths": String(selection.selectedPaths.count),
                "manualCodemapPaths": String(selection.manualCodemapPaths.count),
                "sliceFiles": String(nonEmptySlices.count),
                "sliceRanges": String(sliceRanges),
                "codemapAutoEnabled": String(selection.codemapAutoEnabled)
            ]
        #else
            [:]
        #endif
    }

    private static func compactCallStack() -> String {
        Thread.callStackSymbols
            .dropFirst(3)
            .prefix(10)
            .map { symbol in
                symbol
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: " <- ")
    }
}

package struct WorkspaceRootBindingProjection: Equatable {
    package let sessionID: UUID
    package let replacementsByLogicalRootPath: [String: BoundRoot]
    private let visibleLogicalRoots: [WorkspaceRootRef]
    private let lookupPhysicalRootPaths: Set<String>

    package struct BoundRoot: Equatable {
        package let logicalRoot: WorkspaceRootRef
        package let physicalRoot: WorkspaceRootRef
        package let binding: WorkspaceSessionWorktreeBinding
        package let sessionRootAuthorization: WorkspaceSessionRootAuthorization?

        package init(
            logicalRoot: WorkspaceRootRef,
            physicalRoot: WorkspaceRootRef,
            binding: WorkspaceSessionWorktreeBinding,
            sessionRootAuthorization: WorkspaceSessionRootAuthorization? = nil
        ) {
            self.logicalRoot = logicalRoot
            self.physicalRoot = physicalRoot
            self.binding = binding
            self.sessionRootAuthorization = sessionRootAuthorization
        }
    }

    package init(
        sessionID: UUID,
        boundRoots: [BoundRoot],
        visibleLogicalRoots: [WorkspaceRootRef] = [],
        lookupPhysicalRootPaths: Set<String>? = nil
    ) {
        self.sessionID = sessionID
        var replacements: [String: BoundRoot] = [:]
        for boundRoot in boundRoots {
            replacements[boundRoot.logicalRoot.standardizedFullPath] = boundRoot
        }
        replacementsByLogicalRootPath = replacements
        self.visibleLogicalRoots = visibleLogicalRoots.isEmpty
            ? boundRoots.map(\.logicalRoot)
            : visibleLogicalRoots
        self.lookupPhysicalRootPaths = lookupPhysicalRootPaths
            ?? Set(boundRoots.map(\.physicalRoot.standardizedFullPath))
    }

    package static func logicalAbsolutePath(
        forPhysicalPath rawPath: String,
        binding: WorkspaceSessionWorktreeBinding
    ) -> String? {
        let physicalRoot = StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath)
        let logicalRoot = StandardizedPath.absolute((binding.logicalRootPath as NSString).expandingTildeInPath)
        let physicalPath = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard physicalPath == physicalRoot || physicalPath.hasPrefix(physicalRoot + "/") else { return nil }
        guard physicalPath != physicalRoot else { return logicalRoot }
        let relative = String(physicalPath.dropFirst(physicalRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return StandardizedPath.join(
            standardizedRoot: logicalRoot,
            standardizedRelativePath: relative
        )
    }

    package var isEmpty: Bool {
        replacementsByLogicalRootPath.isEmpty
    }

    var logicalRootPaths: Set<String> {
        Set(replacementsByLogicalRootPath.keys)
    }

    var physicalRootPaths: Set<String> {
        Set(replacementsByLogicalRootPath.values.map(\.physicalRoot.standardizedFullPath))
    }

    var canonicalRootPaths: Set<String> {
        Set(visibleLogicalRoots.map(\.standardizedFullPath)).subtracting(logicalRootPaths)
    }

    package var lookupRootScope: WorkspaceLookupRootScope {
        .validatedSessionBoundWorkspace(
            canonicalRoots: Set(visibleLogicalRootRefs.filter {
                canonicalRootPaths.contains($0.standardizedFullPath)
            }),
            physicalRoots: Set(physicalRootRefs.filter {
                lookupPhysicalRootPaths.contains($0.standardizedFullPath)
            })
        )
    }

    package var isFullyMaterialized: Bool {
        lookupPhysicalRootPaths == physicalRootPaths
    }

    package var logicalRootRefs: [WorkspaceRootRef] {
        replacementsByLogicalRootPath.values
            .map(\.logicalRoot)
            .sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    package var visibleLogicalRootRefs: [WorkspaceRootRef] {
        visibleLogicalRoots.sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    package var physicalRootRefs: [WorkspaceRootRef] {
        Array(Set(replacementsByLogicalRootPath.values.map(\.physicalRoot)))
            .sorted { $0.standardizedFullPath < $1.standardizedFullPath }
    }

    package var boundRootsForMetadata: [BoundRoot] {
        replacementsByLogicalRootPath.values.sorted { lhs, rhs in
            if lhs.logicalRoot.standardizedFullPath != rhs.logicalRoot.standardizedFullPath {
                return lhs.logicalRoot.standardizedFullPath < rhs.logicalRoot.standardizedFullPath
            }
            if lhs.physicalRoot.standardizedFullPath != rhs.physicalRoot.standardizedFullPath {
                return lhs.physicalRoot.standardizedFullPath < rhs.physicalRoot.standardizedFullPath
            }
            return lhs.binding.worktreeID < rhs.binding.worktreeID
        }
    }

    package func translateInputPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawPath }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = expanded.hasPrefix("/") ? StandardizedPath.absolute(expanded) : StandardizedPath.relative(expanded)

        if standardized.hasPrefix("/") {
            if pathIsUnderAnyPhysicalRoot(standardized) {
                return standardized
            }
            if let boundRoot = boundRoot(containingLogicalAbsolutePath: standardized) {
                return replacePrefix(
                    in: standardized,
                    from: boundRoot.logicalRoot.standardizedFullPath,
                    to: boundRoot.physicalRoot.standardizedFullPath
                )
            }
            return standardized
        }

        if let aliasTranslated = translateAliasPrefixedRelativePath(standardized) {
            return aliasTranslated
        }
        if isAliasPrefixedToUnboundLogicalRoot(standardized) {
            return rawPath
        }

        let boundRoots = Array(replacementsByLogicalRootPath.values)
        guard boundRoots.count == 1, let boundRoot = boundRoots.first else { return rawPath }
        return StandardizedPath.join(
            standardizedRoot: boundRoot.physicalRoot.standardizedFullPath,
            standardizedRelativePath: standardized
        )
    }

    package func translateInputPaths(_ paths: [String]) -> [String] {
        paths.map { translateInputPath($0) }
    }

    package func translateSliceInputs(_ slices: [WorkspaceSelectionSliceInput]) -> [WorkspaceSelectionSliceInput] {
        slices.map { input in
            WorkspaceSelectionSliceInput(
                path: translateInputPath(input.path),
                ranges: input.ranges
            )
        }
    }

    package func projectedLogicalRootMetadata(forPhysicalPath rawPath: String) -> (rootPath: String, pathWithinRoot: String)? {
        let standardized = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard let boundRoot = boundRoot(containingPhysicalAbsolutePath: standardized) else {
            return nil
        }
        let relative = String(standardized.dropFirst(boundRoot.physicalRoot.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (boundRoot.logicalRoot.standardizedFullPath, StandardizedPath.relative(relative))
    }

    package func projectedLogicalPathComponents(forPhysicalPath rawPath: String) -> (root: WorkspaceRootRef, relativePath: String)? {
        let standardized = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard let boundRoot = boundRoot(containingPhysicalAbsolutePath: standardized) else {
            return nil
        }
        let relative = String(standardized.dropFirst(boundRoot.physicalRoot.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (boundRoot.logicalRoot, StandardizedPath.relative(relative))
    }

    package func projectedLogicalDisplayPath(forPhysicalPath rawPath: String, display: FilePathDisplay = .relative) -> String? {
        let standardized = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
        guard let boundRoot = boundRoot(containingPhysicalAbsolutePath: standardized) else {
            return nil
        }
        let logicalAbsolute = replacePrefix(
            in: standardized,
            from: boundRoot.physicalRoot.standardizedFullPath,
            to: boundRoot.logicalRoot.standardizedFullPath
        )
        if display == .full {
            return logicalAbsolute
        }
        let relative = String(logicalAbsolute.dropFirst(boundRoot.logicalRoot.standardizedFullPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ClientPathFormatter.displayPath(
            root: boundRoot.logicalRoot,
            relativePath: relative,
            visibleRoots: visibleLogicalRootRefs
        )
    }

    func logicalDisplayPath(forPhysicalPath rawPath: String, display: FilePathDisplay = .relative) -> String {
        projectedLogicalDisplayPath(forPhysicalPath: rawPath, display: display)
            ?? StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
    }

    func logicalizeFileTreeSnapshot(_ snapshot: FileTreeSelectionSnapshot) -> FileTreeSelectionSnapshot {
        FileTreeSelectionSnapshot(
            roots: snapshot.roots.map { logicalizeFolderSnapshot($0) },
            selectedFileIDs: snapshot.selectedFileIDs,
            mode: snapshot.mode,
            showFullPaths: snapshot.showFullPaths,
            onlyIncludeRootsWithSelectedFiles: snapshot.onlyIncludeRootsWithSelectedFiles,
            includeLegend: snapshot.includeLegend,
            showCodeMapMarkers: snapshot.showCodeMapMarkers,
            maxDepth: snapshot.maxDepth
        )
    }

    private func logicalizeFolderSnapshot(_ folder: FileTreeFolderSnapshot) -> FileTreeFolderSnapshot {
        let logicalFullPath = projectedLogicalDisplayPath(forPhysicalPath: folder.fullPath, display: .full)
        let logicalStandardizedFullPath = projectedLogicalDisplayPath(forPhysicalPath: folder.standardizedFullPath, display: .full)
        let logicalStandardizedRootPath = projectedLogicalDisplayPath(forPhysicalPath: folder.standardizedRootPath, display: .full)
        let name: String = if let logicalStandardizedRootPath,
                              logicalStandardizedFullPath == logicalStandardizedRootPath,
                              let boundRoot = replacementsByLogicalRootPath[logicalStandardizedRootPath]
        {
            boundRoot.logicalRoot.name
        } else {
            folder.name
        }
        return FileTreeFolderSnapshot(
            id: folder.id,
            name: name,
            fullPath: logicalFullPath ?? folder.fullPath,
            standardizedFullPath: logicalStandardizedFullPath ?? folder.standardizedFullPath,
            standardizedRootPath: logicalStandardizedRootPath ?? folder.standardizedRootPath,
            children: folder.children.map { child in
                switch child {
                case let .folder(childFolder):
                    .folder(logicalizeFolderSnapshot(childFolder))
                case let .file(file):
                    .file(file)
                }
            }
        )
    }

    package func logicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        var slices: [String: [LineRange]] = [:]
        for (path, ranges) in selection.slices {
            let logicalPath = logicalDisplayPath(forPhysicalPath: path, display: .full)
            slices[logicalPath] = SliceRangeMath.normalize((slices[logicalPath] ?? []) + ranges)
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.map { logicalDisplayPath(forPhysicalPath: $0, display: .full) },
            manualCodemapPaths: selection.manualCodemapPaths.map {
                logicalDisplayPath(forPhysicalPath: $0, display: .full)
            },
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    package func physicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        var slices: [String: [LineRange]] = [:]
        for (path, ranges) in selection.slices {
            let physicalPath = translateInputPath(path)
            slices[physicalPath] = SliceRangeMath.normalize((slices[physicalPath] ?? []) + ranges)
        }
        return StoredSelection(
            selectedPaths: selection.selectedPaths.map { translateInputPath($0) },
            manualCodemapPaths: selection.manualCodemapPaths.map { translateInputPath($0) },
            slices: slices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private func translateAliasPrefixedRelativePath(_ standardizedRelativePath: String) -> String? {
        switch WorkspaceAliasResolver.resolve(
            userPath: standardizedRelativePath,
            roots: visibleLogicalRootRefs,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .bareRoot(root, _):
            guard let boundRoot = replacementsByLogicalRootPath[root.standardizedFullPath] else { return nil }
            return boundRoot.physicalRoot.standardizedFullPath
        case let .prefixed(root, _, remainder):
            guard let boundRoot = replacementsByLogicalRootPath[root.standardizedFullPath] else { return nil }
            return StandardizedPath.join(
                standardizedRoot: boundRoot.physicalRoot.standardizedFullPath,
                standardizedRelativePath: StandardizedPath.relative(remainder)
            )
        case .ambiguous, .notAliasPrefixed:
            return nil
        }
    }

    private func isAliasPrefixedToUnboundLogicalRoot(_ standardizedRelativePath: String) -> Bool {
        switch WorkspaceAliasResolver.resolve(
            userPath: standardizedRelativePath,
            roots: visibleLogicalRootRefs,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .bareRoot(root, _), let .prefixed(root, _, _):
            replacementsByLogicalRootPath[root.standardizedFullPath] == nil
        case .ambiguous, .notAliasPrefixed:
            false
        }
    }

    private func boundRoot(containingLogicalAbsolutePath path: String) -> BoundRoot? {
        replacementsByLogicalRootPath.values
            .filter { path == $0.logicalRoot.standardizedFullPath || path.hasPrefix($0.logicalRoot.standardizedFullPath + "/") }
            .max { $0.logicalRoot.standardizedFullPath.count < $1.logicalRoot.standardizedFullPath.count }
    }

    package func boundRoot(containingPhysicalAbsolutePath path: String) -> BoundRoot? {
        let matches = boundRootsForMetadata.filter {
            path == $0.physicalRoot.standardizedFullPath || path.hasPrefix($0.physicalRoot.standardizedFullPath + "/")
        }
        guard let longestRootPathLength = matches.map(\.physicalRoot.standardizedFullPath.count).max() else { return nil }
        return matches.first { $0.physicalRoot.standardizedFullPath.count == longestRootPathLength }
    }

    private func pathIsUnderAnyPhysicalRoot(_ path: String) -> Bool {
        boundRoot(containingPhysicalAbsolutePath: path) != nil
    }

    private func replacePrefix(in path: String, from oldRoot: String, to newRoot: String) -> String {
        guard path != oldRoot else { return newRoot }
        let suffix = String(path.dropFirst(oldRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return StandardizedPath.join(standardizedRoot: newRoot, standardizedRelativePath: suffix)
    }
}

package struct WorkspaceRootBindingProjectionPreparation {
    package let sessionID: UUID
    let bindings: [WorkspaceSessionWorktreeBinding]
    let visibleRoots: [WorkspaceRootRef]
    let logicalRootsByPath: [String: WorkspaceRootRef]
    package let ownership: WorkspaceSessionWorktreeOwnershipPreparation
    let startupContext: WorktreeStartupContext?
}

package struct WorkspaceRootBindingProjectionMaterializer {
    package let store: WorkspaceFileContextStore

    package init(store: WorkspaceFileContextStore) {
        self.store = store
    }

    package func prepare(
        sessionID: UUID,
        bindings: [WorkspaceSessionWorktreeBinding],
        startupContext: WorktreeStartupContext? = nil,
        initializationHintsByBindingID: [String: WorkspaceRootMaterializationHint] = [:]
    ) async throws -> WorkspaceRootBindingProjectionPreparation {
        let startMS = WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).timestampMSIfEnabled()
        WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).event(
            "projection.prepare.start",
            fields: [
                "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(sessionID),
                "bindingCount": String(bindings.count),
                "bindingFingerprint": String(WorkspaceSessionBindingFingerprint.make(bindings).prefix(16))
            ]
        )
        let visibleRoots = await store.rootRefs(scope: .visibleWorkspace)
        let preparation = try await prepare(
            sessionID: sessionID,
            bindings: bindings,
            visibleRoots: visibleRoots,
            startupContext: startupContext,
            initializationHintsByBindingID: initializationHintsByBindingID
        )
        WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent(
            "projection.prepare",
            startMS: startMS,
            fields: [
                "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(sessionID),
                "bindingCount": String(bindings.count),
                "visibleRootCount": String(visibleRoots.count)
            ]
        )
        return preparation
    }

    package func prepare(
        sessionID: UUID,
        bindings: [WorkspaceSessionWorktreeBinding],
        visibleRoots: [WorkspaceRootRef],
        startupContext: WorktreeStartupContext?,
        initializationHintsByBindingID: [String: WorkspaceRootMaterializationHint]
    ) async throws -> WorkspaceRootBindingProjectionPreparation {
        var visibleRootsByPath: [String: WorkspaceRootRef] = [:]
        for root in visibleRoots {
            guard visibleRootsByPath.updateValue(root, forKey: root.standardizedFullPath) == nil else {
                throw WorkspaceLookupContextResolutionError.unavailableProjection
            }
        }
        var logicalRootsByPath: [String: WorkspaceRootRef] = [:]
        for binding in bindings {
            let logicalPath = StandardizedPath.absolute(
                (binding.logicalRootPath as NSString).expandingTildeInPath
            )
            guard logicalRootsByPath[logicalPath] == nil,
                  let logicalRoot = visibleRootsByPath[logicalPath]
            else {
                throw WorkspaceLookupContextResolutionError.unavailableProjection
            }
            logicalRootsByPath[logicalPath] = logicalRoot
        }

        let ownershipStartMS = WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).timestampMSIfEnabled()
        var initializationHintsByPhysicalRootPath: [String: WorkspaceRootMaterializationHint] = [:]
        #if DEBUG
            var receiptProjectionDecision = WorkspaceContextStartupInstrumentation.ReceiptProjectionDecision()
            receiptProjectionDecision.suppliedHintCount = initializationHintsByBindingID.count
            receiptProjectionDecision.allHintKeysMatchedBindings = Set(initializationHintsByBindingID.keys)
                .isSubset(of: Set(bindings.map(\.id)))
        #endif
        for binding in bindings {
            guard let hint = initializationHintsByBindingID[binding.id] else { continue }
            let physicalPath = StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath)
            let validatedHint = hint.validated(
                matching: binding,
                sessionID: sessionID,
                startupContext: startupContext
            )
            initializationHintsByPhysicalRootPath[physicalPath] = validatedHint
            #if DEBUG
                receiptProjectionDecision.matchedHintCount += 1
                receiptProjectionDecision.validationFallback = receiptProjectionDecision.validationFallback
                    ?? validatedHint.validationFallbackReason
            #endif
        }
        #if DEBUG
            if let startupContext {
                WorkspaceContextStartupInstrumentation.recordReceiptProjectionDecision(
                    correlationID: startupContext.correlationID,
                    decision: receiptProjectionDecision
                )
            }
        #endif
        let ownership = try await store.prepareSessionWorktreeOwnership(
            ownerID: sessionID,
            bindingFingerprint: WorkspaceSessionBindingFingerprint.make(bindings),
            physicalRootPaths: bindings.map(\.worktreeRootPath),
            startupContext: startupContext,
            initializationHintsByPhysicalRootPath: initializationHintsByPhysicalRootPath
        )
        WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent(
            "projection.prepareOwnership",
            startMS: ownershipStartMS,
            fields: [
                "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(sessionID),
                "bindingCount": String(bindings.count),
                "physicalRootCount": String(bindings.map(\.worktreeRootPath).count)
            ]
        )
        return WorkspaceRootBindingProjectionPreparation(
            sessionID: sessionID,
            bindings: bindings,
            visibleRoots: visibleRoots,
            logicalRootsByPath: logicalRootsByPath,
            ownership: ownership,
            startupContext: startupContext
        )
    }

    package func commit(
        _ preparation: WorkspaceRootBindingProjectionPreparation
    ) async throws -> WorkspaceRootBindingProjection? {
        let startMS = WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).timestampMSIfEnabled()
        let commitOwnershipStartMS = WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).timestampMSIfEnabled()
        let records: [WorkspaceSessionWorktreeOwnedRoot]
        do {
            records = try await store.commitSessionWorktreeOwnership(preparation.ownership)
        } catch {
            #if DEBUG
                await store.terminalizeReceiptConsumptionDecision(preparation.ownership)
            #endif
            throw error
        }
        WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent(
            "projection.commitOwnership",
            startMS: commitOwnershipStartMS,
            fields: [
                "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(preparation.sessionID),
                "recordCount": String(records.count),
                "bindingCount": String(preparation.bindings.count)
            ]
        )
        if let startupContext = preparation.startupContext {
            WorkspaceContextStartupInstrumentation.record(.rootReady, context: startupContext)
        }
        guard !preparation.bindings.isEmpty else { return nil }

        do {
            var recordsByPath: [String: WorkspaceSessionWorktreeOwnedRoot] = [:]
            for record in records {
                if let existing = recordsByPath[record.standardizedPhysicalPath], existing != record {
                    throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(record.standardizedPhysicalPath)
                }
                recordsByPath[record.standardizedPhysicalPath] = record
            }

            var physicalRootsByID: [UUID: WorkspaceRootRef] = [:]
            var boundRoots: [WorkspaceRootBindingProjection.BoundRoot] = []
            for binding in preparation.bindings {
                let logicalPath = StandardizedPath.absolute(
                    (binding.logicalRootPath as NSString).expandingTildeInPath
                )
                guard let logicalRoot = preparation.logicalRootsByPath[logicalPath] else {
                    throw WorkspaceLookupContextResolutionError.unavailableProjection
                }
                let physicalPath = StandardizedPath.absolute(
                    (binding.worktreeRootPath as NSString).expandingTildeInPath
                )
                guard let physicalRecord = recordsByPath[physicalPath] else {
                    throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(physicalPath)
                }
                let physicalRoot: WorkspaceRootRef
                if let existing = physicalRootsByID[physicalRecord.rootID] {
                    guard existing.standardizedFullPath == physicalRecord.standardizedPhysicalPath else {
                        throw WorkspaceSessionWorktreeOwnershipError.unavailableRoot(physicalPath)
                    }
                    physicalRoot = existing
                } else {
                    physicalRoot = WorkspaceRootRef(
                        id: physicalRecord.rootID,
                        name: URL(fileURLWithPath: physicalRecord.standardizedPhysicalPath).lastPathComponent,
                        fullPath: physicalRecord.standardizedPhysicalPath
                    )
                    physicalRootsByID[physicalRecord.rootID] = physicalRoot
                }
                boundRoots.append(.init(
                    logicalRoot: logicalRoot,
                    physicalRoot: physicalRoot,
                    binding: binding,
                    sessionRootAuthorization: WorkspaceSessionRootAuthorization(
                        sessionID: preparation.sessionID,
                        ownershipGeneration: preparation.ownership.token.generation,
                        root: physicalRoot,
                        lifetimeID: physicalRecord.lifetimeID
                    )
                ))
            }
            let projection = WorkspaceRootBindingProjection(
                sessionID: preparation.sessionID,
                boundRoots: boundRoots,
                visibleLogicalRoots: preparation.visibleRoots
            )
            WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent(
                "projection.commit",
                startMS: startMS,
                fields: [
                    "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(preparation.sessionID),
                    "boundRootCount": String(boundRoots.count),
                    "visibleRootCount": String(preparation.visibleRoots.count),
                    "fullyMaterialized": String(projection.isFullyMaterialized)
                ]
            )
            return projection
        } catch {
            _ = await store.releaseSessionWorktreeOwnership(ifOwnedBy: preparation.ownership.token)
            throw error
        }
    }

    package func abort(_ preparation: WorkspaceRootBindingProjectionPreparation) async {
        await store.abortSessionWorktreeOwnership(preparation.ownership)
    }

    package func release(ifOwnedBy token: WorkspaceSessionWorktreeOwnershipToken) async {
        _ = await store.releaseSessionWorktreeOwnership(ifOwnedBy: token)
    }

    package func release(sessionID: UUID) async {
        await store.releaseSessionWorktreeOwnership(ownerID: sessionID)
    }

    package func materialize(
        sessionID: UUID,
        bindings: [WorkspaceSessionWorktreeBinding]
    ) async -> WorkspaceRootBindingProjection? {
        await FileSystemService.withContentReadForegroundActivity(kind: .materialization) {
            await materializeWithinForegroundActivity(
                sessionID: sessionID,
                bindings: bindings,
                visibleRoots: nil
            )
        }
    }

    package func materialize(
        sessionID: UUID,
        bindings: [WorkspaceSessionWorktreeBinding],
        visibleRoots: [WorkspaceRootRef]
    ) async -> WorkspaceRootBindingProjection? {
        await FileSystemService.withContentReadForegroundActivity(kind: .materialization) {
            await materializeWithinForegroundActivity(
                sessionID: sessionID,
                bindings: bindings,
                visibleRoots: visibleRoots
            )
        }
    }

    private func materializeWithinForegroundActivity(
        sessionID: UUID,
        bindings: [WorkspaceSessionWorktreeBinding],
        visibleRoots suppliedVisibleRoots: [WorkspaceRootRef]?
    ) async -> WorkspaceRootBindingProjection? {
        let startMS = WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).timestampMSIfEnabled()
        WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).event(
            "projection.materialize.start",
            fields: [
                "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(sessionID),
                "bindingCount": String(bindings.count),
                "bindingFingerprint": String(WorkspaceSessionBindingFingerprint.make(bindings).prefix(16))
            ]
        )
        #if DEBUG
            let coldStartCollector = WorkspaceFileSearchDebugContext.coldStartCollector
            let materializationStart = WorkspaceFileSearchDebugTiming.now()
            var prepareNanoseconds: UInt64 = 0
            var commitNanoseconds: UInt64 = 0
        #endif
        let visibleRootsStartMS = WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).timestampMSIfEnabled()
        let visibleRoots = if let suppliedVisibleRoots {
            suppliedVisibleRoots
        } else {
            await store.rootRefs(scope: .visibleWorkspace)
        }
        WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent(
            "projection.materialize.visibleRoots",
            startMS: visibleRootsStartMS,
            fields: ["visibleRootCount": String(visibleRoots.count)]
        )
        do {
            #if DEBUG
                let prepareStart = WorkspaceFileSearchDebugTiming.now()
            #endif
            let preparation = try await prepare(
                sessionID: sessionID,
                bindings: bindings,
                visibleRoots: visibleRoots,
                startupContext: nil,
                initializationHintsByBindingID: [:]
            )
            #if DEBUG
                prepareNanoseconds = WorkspaceFileSearchDebugTiming.elapsed(
                    since: prepareStart,
                    through: WorkspaceFileSearchDebugTiming.now()
                )
            #endif
            do {
                #if DEBUG
                    let commitStart = WorkspaceFileSearchDebugTiming.now()
                #endif
                let projection = try await commit(preparation)
                #if DEBUG
                    commitNanoseconds = WorkspaceFileSearchDebugTiming.elapsed(
                        since: commitStart,
                        through: WorkspaceFileSearchDebugTiming.now()
                    )
                    coldStartCollector?.recordMaterialization(
                        totalNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                            since: materializationStart,
                            through: WorkspaceFileSearchDebugTiming.now()
                        ),
                        prepareNanoseconds: prepareNanoseconds,
                        commitNanoseconds: commitNanoseconds
                    )
                #endif
                WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent(
                    "projection.materialize.complete",
                    startMS: startMS,
                    fields: [
                        "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(sessionID),
                        "bindingCount": String(bindings.count),
                        "result": projection == nil ? "nil" : "projection",
                        "physicalRootCount": String(projection?.physicalRootRefs.count ?? 0)
                    ]
                )
                return projection
            } catch {
                await abort(preparation)
                #if DEBUG
                    coldStartCollector?.recordMaterialization(
                        totalNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                            since: materializationStart,
                            through: WorkspaceFileSearchDebugTiming.now()
                        ),
                        prepareNanoseconds: prepareNanoseconds,
                        commitNanoseconds: commitNanoseconds
                    )
                #endif
                WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent(
                    "projection.materialize.commitFailed",
                    startMS: startMS,
                    fields: [
                        "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(sessionID),
                        "bindingCount": String(bindings.count),
                        "error": String(describing: error)
                    ]
                )
                return nil
            }
        } catch {
            #if DEBUG
                coldStartCollector?.recordMaterialization(
                    totalNanoseconds: WorkspaceFileSearchDebugTiming.elapsed(
                        since: materializationStart,
                        through: WorkspaceFileSearchDebugTiming.now()
                    ),
                    prepareNanoseconds: prepareNanoseconds,
                    commitNanoseconds: commitNanoseconds
                )
            #endif
            WorkspaceSelectedFilesDiagnostics(perfRecorder: store.perfRecorder).durationEvent(
                "projection.materialize.prepareFailed",
                startMS: startMS,
                fields: [
                    "sessionID": WorkspaceSelectedFilesDiagnostics.shortID(sessionID),
                    "bindingCount": String(bindings.count),
                    "error": String(describing: error)
                ]
            )
            return nil
        }
    }
}

package struct WorkspaceLookupContext: Equatable {
    package let rootScope: WorkspaceLookupRootScope
    package let bindingProjection: WorkspaceRootBindingProjection?

    package init(rootScope: WorkspaceLookupRootScope, bindingProjection: WorkspaceRootBindingProjection?) {
        self.rootScope = rootScope
        self.bindingProjection = bindingProjection
    }

    package static let visibleWorkspace = WorkspaceLookupContext(rootScope: .visibleWorkspace, bindingProjection: nil)

    package func translateInputPath(_ path: String) -> String {
        bindingProjection?.translateInputPath(path) ?? path
    }

    package func translateInputPaths(_ paths: [String]) -> [String] {
        bindingProjection?.translateInputPaths(paths) ?? paths
    }

    package func translateSliceInputs(_ slices: [WorkspaceSelectionSliceInput]) -> [WorkspaceSelectionSliceInput] {
        bindingProjection?.translateSliceInputs(slices) ?? slices
    }

    package func displayPath(forPhysicalPath path: String, display: FilePathDisplay = .relative) -> String {
        bindingProjection?.logicalDisplayPath(forPhysicalPath: path, display: display) ?? path
    }

    package func logicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        bindingProjection?.logicalizeSelection(selection) ?? selection
    }

    package func physicalizeSelection(_ selection: StoredSelection) -> StoredSelection {
        bindingProjection?.physicalizeSelection(selection) ?? selection
    }

    package func exactFileNamespace(storeRoots: [WorkspaceRootRef]) -> WorkspaceExactFileNamespace {
        guard let bindingProjection else { return .identity(roots: storeRoots) }
        let boundRoots = bindingProjection.boundRootsForMetadata
        let visibleLogicalRoots = bindingProjection.visibleLogicalRootRefs
        var bindings = storeRoots.map { lookupRoot in
            let logicalMatches = boundRoots
                .filter { $0.physicalRoot.standardizedFullPath == lookupRoot.standardizedFullPath }
                .map(\.logicalRoot)
            let canonicalMatch = visibleLogicalRoots.first {
                $0.standardizedFullPath == lookupRoot.standardizedFullPath
            }
            let clientRoots = logicalMatches.isEmpty ? [canonicalMatch ?? lookupRoot] : logicalMatches
            let sortedClientRoots = clientRoots.sorted { $0.standardizedFullPath < $1.standardizedFullPath }
            return WorkspaceExactFileNamespace.RootBinding(
                lookupRoot: lookupRoot,
                lookupRole: logicalMatches.isEmpty ? .canonical : .projectedPhysical,
                clientRoots: sortedClientRoots,
                preferredClientRoot: sortedClientRoots[0]
            )
        }
        let representedPhysicalPaths = Set(storeRoots.map(\.standardizedFullPath))
        let unavailableByPhysicalPath = Dictionary(grouping: boundRoots) {
            $0.physicalRoot.standardizedFullPath
        }
        for physicalPath in unavailableByPhysicalPath.keys.sorted()
            where !representedPhysicalPaths.contains(physicalPath)
        {
            guard let unavailableRoots = unavailableByPhysicalPath[physicalPath] else { continue }
            let lookupRoot = unavailableRoots
                .map(\.physicalRoot)
                .sorted { $0.id.uuidString < $1.id.uuidString }[0]
            var seenLogicalPaths: Set<String> = []
            let clientRoots = unavailableRoots
                .map(\.logicalRoot)
                .sorted { $0.standardizedFullPath < $1.standardizedFullPath }
                .filter { seenLogicalPaths.insert($0.standardizedFullPath).inserted }
            bindings.append(WorkspaceExactFileNamespace.RootBinding(
                lookupRoot: lookupRoot,
                lookupRole: .projectedPhysical,
                clientRoots: clientRoots,
                preferredClientRoot: clientRoots[0]
            ))
        }
        return WorkspaceExactFileNamespace(rootBindings: bindings)
    }

    package func domainMutationPhysicalRootMappings(
        store: WorkspaceFileContextStore
    ) async -> [DomainMutationPhysicalRootMapping] {
        let roots = await store.rootRefs(scope: rootScope)
        let boundRoots = bindingProjection?.boundRootsForMetadata ?? []
        return roots.map { root in
            let physical = root.standardizedFullPath
            let canonical = boundRoots.first {
                $0.physicalRoot.standardizedFullPath == physical
            }?.logicalRoot.standardizedFullPath ?? physical
            return DomainMutationPhysicalRootMapping(
                canonicalRoot: canonical,
                physicalRoot: physical
            )
        }
    }
}

/// App-independent diagnostic events. The app adapter owns counters, task-local tags, and logs.
package enum WorkspaceStartupDiagnosticEvent {
    case phase(WorktreeStartupPhaseEvent)
    case inventoryComparison(matched: Bool)
    case shadowFallback(WorkspaceRootSeedFallbackReason)
    case projectedSearchComparison(matched: Bool, baseEntryCount: Int, overlayEntryCount: Int, tombstoneCount: Int)
    case seedReceiptJournalCut(present: Bool)
    case seedReplay(acceptedPayloadCount: Int, acceptedEventCount: Int, initializationWatermarkDelta: Int, serviceSequenceDelta: Int, changedPathCount: Int)
    case seedMetadataRevalidation(used: Bool)
    case seedProjectedPreparation(baseEntryCount: Int, overlayEntryCount: Int, tombstoneCount: Int)
    case seedFullCrawlFallback
    #if DEBUG
        case receiptProjection(correlationID: UUID, decision: WorkspaceReceiptProjectionDecision, terminal: Bool)
        case receiptConsumption(correlationID: UUID, decision: WorkspaceReceiptConsumptionDecision, terminal: Bool)
        case deltaCompatibility(
            correlationID: UUID,
            evaluation: WorkspaceRootSeedDeltaCompatibilityEvaluation,
            policyCanonicalizationComparison: GitWorkspacePolicyCanonicalizationDiagnostics.Comparison?,
            exactSnapshotLookupReached: Bool,
            exactSnapshotLookupPassed: Bool,
            targetAuthorityComparisonReached: Bool,
            targetAuthorityComparisonPassed: Bool,
            currentSearchABIReached: Bool,
            currentSearchABIMatched: Bool?,
            catalogPolicyComparisonReached: Bool,
            catalogPolicyMatched: Bool?,
            terminalFallback: WorkspaceRootSeedFallbackReason?
        )
        case benchmarkPlannerPhase(tag: WorkspaceBenchmarkMetricTag?, phase: WorkspaceBenchmarkPlannerPhase, durationMicroseconds: UInt64, itemCount: Int)
        case benchmarkPassiveTree(tag: WorkspaceBenchmarkMetricTag?, durationMicroseconds: UInt64)
        case benchmarkFilesystemWork(tag: WorkspaceBenchmarkMetricTag?, durationMicroseconds: UInt64, itemCount: Int)
        case benchmarkCodemapWork(tag: WorkspaceBenchmarkMetricTag?, durations: CodeMapArtifactCoordinatorDurations?, buildPerformed: Bool, exactlyAttributed: Bool)
        case benchmarkMarkerPublication(tag: WorkspaceBenchmarkMetricTag?, rootID: UUID, rootLifetimeID: UUID, revision: UInt64, effectiveChangeCount: Int, source: WorkspaceBenchmarkMarkerPublicationSource)
    #endif
}

package protocol WorkspaceStartupEventRecording: Sendable {
    func record(_ event: WorkspaceStartupDiagnosticEvent)
    #if DEBUG
        var currentBenchmarkMetricTag: WorkspaceBenchmarkMetricTag? {
            get
        }
    #endif
}

package extension WorktreeStartupFeatureFlags {
    /// A standalone store has no application preferences domain.
    static func standaloneOperationalDefault() -> Self {
        Self(observeDiffSeededWorktreeStartup: true, serveDiffSeededWorktreeStartup: true)
    }
}

package enum WorkspaceContextStartupInstrumentation {
    #if DEBUG
        typealias ReceiptProjectionDecision = WorkspaceReceiptProjectionDecision
        typealias ReceiptConsumptionDecision = WorkspaceReceiptConsumptionDecision
        typealias BenchmarkMetricTag = WorkspaceBenchmarkMetricTag
    #endif

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var recorder: (any WorkspaceStartupEventRecording)?
    }

    private static let storage = Storage()

    package static func install(_ recorder: (any WorkspaceStartupEventRecording)?) {
        storage.lock.lock()
        storage.recorder = recorder
        storage.lock.unlock()
    }

    static func currentRecorder() -> (any WorkspaceStartupEventRecording)? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.recorder
    }

    private static func emit(_ event: WorkspaceStartupDiagnosticEvent) {
        currentRecorder()?.record(event)
    }

    static func record(
        _ phase: WorktreeStartupPhase,
        context: WorktreeStartupContext,
        route: WorkspaceRootStartupRoute? = nil,
        fallback: WorkspaceRootSeedFallbackReason? = nil
    ) {
        emit(.phase(WorktreeStartupPhaseEvent(phase: phase, context: context, route: route, fallback: fallback)))
    }

    static func recordInventoryComparison(matched: Bool) {
        emit(.inventoryComparison(matched: matched))
    }

    static func recordShadowFallback(_ reason: WorkspaceRootSeedFallbackReason) {
        emit(.shadowFallback(reason))
    }

    static func recordProjectedSearchComparison(matched: Bool, baseEntryCount: Int, overlayEntryCount: Int, tombstoneCount: Int) {
        emit(.projectedSearchComparison(matched: matched, baseEntryCount: baseEntryCount, overlayEntryCount: overlayEntryCount, tombstoneCount: tombstoneCount))
    }

    static func recordSeedReceiptJournalCut(present: Bool) {
        emit(.seedReceiptJournalCut(present: present))
    }

    static func recordSeedReplay(acceptedPayloadCount: Int, acceptedEventCount: Int, initializationWatermarkDelta: Int, serviceSequenceDelta: Int, changedPathCount: Int) {
        emit(.seedReplay(acceptedPayloadCount: acceptedPayloadCount, acceptedEventCount: acceptedEventCount, initializationWatermarkDelta: initializationWatermarkDelta, serviceSequenceDelta: serviceSequenceDelta, changedPathCount: changedPathCount))
    }

    static func recordSeedMetadataRevalidation(used: Bool) {
        emit(.seedMetadataRevalidation(used: used))
    }

    static func recordSeedProjectedPreparation(baseEntryCount: Int, overlayEntryCount: Int, tombstoneCount: Int) {
        emit(.seedProjectedPreparation(baseEntryCount: baseEntryCount, overlayEntryCount: overlayEntryCount, tombstoneCount: tombstoneCount))
    }

    static func recordSeedFullCrawlFallback() {
        emit(.seedFullCrawlFallback)
    }

    #if DEBUG
        static var currentBenchmarkMetricTag: BenchmarkMetricTag? {
            currentRecorder()?.currentBenchmarkMetricTag
        }

        static func recordReceiptProjectionDecision(correlationID: UUID, decision: ReceiptProjectionDecision, terminal: Bool = false) {
            emit(.receiptProjection(correlationID: correlationID, decision: decision, terminal: terminal))
        }

        static func recordReceiptConsumptionDecision(correlationID: UUID, decision: ReceiptConsumptionDecision, terminal: Bool = true) {
            emit(.receiptConsumption(correlationID: correlationID, decision: decision, terminal: terminal))
        }

        static func recordDeltaCompatibilityEvaluation(
            correlationID: UUID,
            evaluation: WorkspaceRootSeedDeltaCompatibilityEvaluation,
            policyCanonicalizationComparison: GitWorkspacePolicyCanonicalizationDiagnostics.Comparison? = nil,
            exactSnapshotLookupReached: Bool,
            exactSnapshotLookupPassed: Bool,
            targetAuthorityComparisonReached: Bool,
            targetAuthorityComparisonPassed: Bool,
            currentSearchABIReached: Bool,
            currentSearchABIMatched: Bool?,
            catalogPolicyComparisonReached: Bool,
            catalogPolicyMatched: Bool?,
            terminalFallback: WorkspaceRootSeedFallbackReason?
        ) {
            emit(.deltaCompatibility(
                correlationID: correlationID,
                evaluation: evaluation,
                policyCanonicalizationComparison: policyCanonicalizationComparison,
                exactSnapshotLookupReached: exactSnapshotLookupReached,
                exactSnapshotLookupPassed: exactSnapshotLookupPassed,
                targetAuthorityComparisonReached: targetAuthorityComparisonReached,
                targetAuthorityComparisonPassed: targetAuthorityComparisonPassed,
                currentSearchABIReached: currentSearchABIReached,
                currentSearchABIMatched: currentSearchABIMatched,
                catalogPolicyComparisonReached: catalogPolicyComparisonReached,
                catalogPolicyMatched: catalogPolicyMatched,
                terminalFallback: terminalFallback
            ))
        }

        static func recordBenchmarkPlannerPhase(tag: BenchmarkMetricTag?, phase: WorkspaceBenchmarkPlannerPhase, durationMicroseconds: UInt64, itemCount: Int) {
            emit(.benchmarkPlannerPhase(tag: tag, phase: phase, durationMicroseconds: durationMicroseconds, itemCount: itemCount))
        }

        static func recordBenchmarkPassiveTree(tag: BenchmarkMetricTag?, durationMicroseconds: UInt64) {
            emit(.benchmarkPassiveTree(tag: tag, durationMicroseconds: durationMicroseconds))
        }

        static func recordBenchmarkFilesystemWork(tag: BenchmarkMetricTag?, durationMicroseconds: UInt64, itemCount: Int) {
            emit(.benchmarkFilesystemWork(tag: tag, durationMicroseconds: durationMicroseconds, itemCount: itemCount))
        }

        static func recordBenchmarkCodemapWork(tag: BenchmarkMetricTag?, durations: CodeMapArtifactCoordinatorDurations?, buildPerformed: Bool, exactlyAttributed: Bool) {
            emit(.benchmarkCodemapWork(tag: tag, durations: durations, buildPerformed: buildPerformed, exactlyAttributed: exactlyAttributed))
        }

        static func recordBenchmarkMarkerPublication(tag: BenchmarkMetricTag?, rootID: UUID, rootLifetimeID: UUID, revision: UInt64, effectiveChangeCount: Int, source: WorkspaceBenchmarkMarkerPublicationSource) {
            emit(.benchmarkMarkerPublication(tag: tag, rootID: rootID, rootLifetimeID: rootLifetimeID, revision: revision, effectiveChangeCount: effectiveChangeCount, source: source))
        }
    #endif
}
