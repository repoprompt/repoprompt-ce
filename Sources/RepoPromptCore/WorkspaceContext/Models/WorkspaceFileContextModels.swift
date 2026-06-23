import Foundation

package enum WorkspaceLookupRootScope: Hashable {
    case visibleWorkspace
    case visibleWorkspacePlusGitData
    case allLoaded
    case allLoadedExcludingGitData
    case sessionBoundWorkspace(canonicalRootPaths: Set<String>, physicalRootPaths: Set<String>)
    case validatedSessionBoundWorkspace(
        canonicalRoots: Set<WorkspaceRootRef>,
        physicalRoots: Set<WorkspaceRootRef>
    )
}

package enum WorkspaceLookupRootScopeAvailability: Equatable {
    case available
    case sessionWorktreeUnavailable(missingPhysicalRootPaths: [String])
}

package enum WorkspaceRootKind: Hashable {
    case primaryWorkspace
    case workspaceGitData
    case supplementalSystem
    case sessionWorktree
}

package struct WorkspaceRootLoadFailure: Equatable, Identifiable {
    package let id: UUID
    package let rootPath: String
    package let standardizedRootPath: String
    package let kind: WorkspaceRootKind
    package let errorDescription: String

    package init(id: UUID = UUID(), rootPath: String, kind: WorkspaceRootKind, errorDescription: String) {
        self.id = id
        self.rootPath = rootPath
        standardizedRootPath = StandardizedPath.absolute(rootPath)
        self.kind = kind
        self.errorDescription = errorDescription
    }

    package static func == (lhs: WorkspaceRootLoadFailure, rhs: WorkspaceRootLoadFailure) -> Bool {
        lhs.standardizedRootPath == rhs.standardizedRootPath &&
            lhs.kind == rhs.kind &&
            lhs.errorDescription == rhs.errorDescription
    }
}

package struct WorkspaceSearchReadinessTicket: Equatable, Hashable {
    package let workspaceID: UUID?
    package let generation: UInt64

    package init(workspaceID: UUID?, generation: UInt64) {
        self.workspaceID = workspaceID
        self.generation = generation
    }
}

package enum WorkspaceSearchReadinessWaitError: Error, Equatable {
    case unavailable
    case timedOut
    case superseded
}

package enum WorkspaceSearchReadinessState: Equatable {
    case idle
    case activating(workspaceID: UUID?, generation: UInt64)
    case loadingCatalog(workspaceID: UUID?, generation: UInt64, loadedRootCount: Int, expectedRootCount: Int, failures: [WorkspaceRootLoadFailure])
    case buildingIndexes(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64, failures: [WorkspaceRootLoadFailure])
    case ready(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64, indexedGeneration: UInt64, diagnostics: WorkspaceCatalogDiagnostics)
    case degraded(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64?, indexedGeneration: UInt64?, failures: [WorkspaceRootLoadFailure], diagnostics: WorkspaceCatalogDiagnostics?)

    package var ticket: WorkspaceSearchReadinessTicket? {
        switch self {
        case .idle:
            nil
        case let .activating(workspaceID, generation),
             let .loadingCatalog(workspaceID, generation, _, _, _),
             let .buildingIndexes(workspaceID, generation, _, _),
             let .ready(workspaceID, generation, _, _, _),
             let .degraded(workspaceID, generation, _, _, _, _):
            WorkspaceSearchReadinessTicket(workspaceID: workspaceID, generation: generation)
        }
    }

    package var isSearchAdmissible: Bool {
        switch self {
        case .ready, .degraded:
            true
        case .idle, .activating, .loadingCatalog, .buildingIndexes:
            false
        }
    }
}

package struct WorkspaceCatalogDiagnostics: Equatable {
    package let generation: UInt64
    package let rootScope: WorkspaceLookupRootScope
    package let rootCount: Int
    package let folderCount: Int
    package let fileCount: Int
    package let totalItemCount: Int

    package init(
        generation: UInt64,
        rootScope: WorkspaceLookupRootScope,
        rootCount: Int,
        folderCount: Int,
        fileCount: Int
    ) {
        self.generation = generation
        self.rootScope = rootScope
        self.rootCount = rootCount
        self.folderCount = folderCount
        self.fileCount = fileCount
        totalItemCount = folderCount + fileCount
    }
}

package struct WorkspaceSearchCatalogEntry: Identifiable, Equatable, Hashable {
    package let id: UUID
    package let rootID: UUID
    package let rootPath: String
    package let rootName: String
    package let name: String
    package let relativePath: String
    package let standardizedRelativePath: String
    package let fullPath: String
    package let standardizedFullPath: String
    package let displayPath: String

    package init(file: WorkspaceFileRecord, root: WorkspaceRootRecord, displayPath: String? = nil) {
        id = file.id
        rootID = file.rootID
        rootPath = root.standardizedFullPath
        rootName = root.name
        name = file.name
        relativePath = file.relativePath
        standardizedRelativePath = file.standardizedRelativePath
        fullPath = file.fullPath
        standardizedFullPath = file.standardizedFullPath
        self.displayPath = displayPath ?? WorkspaceSearchCatalogEntry.defaultDisplayPath(file: file, root: root)
    }

    private static func defaultDisplayPath(file: WorkspaceFileRecord, root: WorkspaceRootRecord) -> String {
        guard !file.standardizedRelativePath.isEmpty else { return root.name }
        return root.name + "/" + file.standardizedRelativePath
    }
}

// Opaque ARC lease keeping immutable catalog generations alive for snapshot readers.

package enum WorkspaceSearchCatalogAccessRequirement: Equatable {
    case recordsOnly
    case recordsAndPathIndexes

    package func satisfies(_ requirement: WorkspaceSearchCatalogAccessRequirement) -> Bool {
        switch (self, requirement) {
        case (.recordsAndPathIndexes, _), (.recordsOnly, .recordsOnly):
            true
        case (.recordsOnly, .recordsAndPathIndexes):
            false
        }
    }

    package var requiresPathIndexes: Bool {
        self == .recordsAndPathIndexes
    }
}

package struct WorkspaceSearchQueryResult: Equatable {
    package let query: String
    package let indexedGeneration: UInt64?
    package let snapshotGeneration: UInt64?
    package let pendingGeneration: UInt64?
    package let observedGeneration: UInt64?
    package let results: [WorkspaceSearchCatalogEntry]
    package let isIndexReady: Bool
    package let isStale: Bool

    package init(
        query: String,
        indexedGeneration: UInt64?,
        snapshotGeneration: UInt64?,
        pendingGeneration: UInt64? = nil,
        observedGeneration: UInt64? = nil,
        results: [WorkspaceSearchCatalogEntry],
        isIndexReady: Bool,
        isStale: Bool = false
    ) {
        self.query = query
        self.indexedGeneration = indexedGeneration
        self.snapshotGeneration = snapshotGeneration
        self.pendingGeneration = pendingGeneration
        self.observedGeneration = observedGeneration
        self.results = results
        self.isIndexReady = isIndexReady
        self.isStale = isStale
    }
}

package struct WorkspaceResolvedCandidates: Equatable {
    package let candidates: [WorkspaceFileRecord]
    package let resolvedMap: [String: String]
    package let invalidPaths: [String]

    package init(candidates: [WorkspaceFileRecord], resolvedMap: [String: String], invalidPaths: [String]) {
        self.candidates = candidates
        self.resolvedMap = resolvedMap
        self.invalidPaths = invalidPaths
    }
}

package struct WorkspaceCodemapOnlyCandidates: Equatable {
    package let candidates: [WorkspaceFileRecord]
    package let resolvedMap: [String: String]
    package let invalidPaths: [String]
    package let codemapUnavailable: [String]

    package init(
        candidates: [WorkspaceFileRecord],
        resolvedMap: [String: String],
        invalidPaths: [String],
        codemapUnavailable: [String]
    ) {
        self.candidates = candidates
        self.resolvedMap = resolvedMap
        self.invalidPaths = invalidPaths
        self.codemapUnavailable = codemapUnavailable
    }
}

package struct WorkspaceRootRecord: Identifiable, Equatable, Hashable {
    package let id: UUID
    package let name: String
    package let fullPath: String
    package let standardizedFullPath: String
    package let isSystemRoot: Bool
    package let kind: WorkspaceRootKind

    package init(id: UUID = UUID(), name: String, fullPath: String, isSystemRoot: Bool = false) {
        self.init(
            id: id,
            name: name,
            fullPath: fullPath,
            kind: isSystemRoot ? .supplementalSystem : .primaryWorkspace,
            isSystemRoot: isSystemRoot
        )
    }

    package init(id: UUID = UUID(), name: String, fullPath: String, kind: WorkspaceRootKind) {
        self.init(
            id: id,
            name: name,
            fullPath: fullPath,
            kind: kind,
            isSystemRoot: kind != .primaryWorkspace
        )
    }

    private init(id: UUID, name: String, fullPath: String, kind: WorkspaceRootKind, isSystemRoot: Bool) {
        self.id = id
        self.name = name
        self.fullPath = fullPath
        standardizedFullPath = (fullPath as NSString).standardizingPath
        self.isSystemRoot = isSystemRoot
        self.kind = kind
    }
}

package struct WorkspaceFolderRecord: Identifiable, Equatable, Hashable {
    package let id: UUID
    package let rootID: UUID
    package let name: String
    package let relativePath: String
    package let standardizedRelativePath: String
    package let fullPath: String
    package let standardizedFullPath: String
    package let parentFolderID: UUID?
    package let modificationDate: Date?

    package init(
        id: UUID = UUID(),
        rootID: UUID,
        name: String,
        relativePath: String,
        fullPath: String,
        parentFolderID: UUID?,
        modificationDate: Date? = nil
    ) {
        self.id = id
        self.rootID = rootID
        self.name = name
        self.relativePath = relativePath
        standardizedRelativePath = StandardizedPath.relative(relativePath)
        self.fullPath = fullPath
        standardizedFullPath = (fullPath as NSString).standardizingPath
        self.parentFolderID = parentFolderID
        self.modificationDate = modificationDate
    }
}

package struct WorkspaceFileRecord: Identifiable, Equatable, Hashable {
    package let id: UUID
    package let rootID: UUID
    package let name: String
    package let relativePath: String
    package let standardizedRelativePath: String
    package let fullPath: String
    package let standardizedFullPath: String
    package let parentFolderID: UUID?
    package let modificationDate: Date?

    package init(
        id: UUID = UUID(),
        rootID: UUID,
        name: String,
        relativePath: String,
        fullPath: String,
        parentFolderID: UUID?,
        modificationDate: Date? = nil
    ) {
        self.id = id
        self.rootID = rootID
        self.name = name
        self.relativePath = relativePath
        standardizedRelativePath = StandardizedPath.relative(relativePath)
        self.fullPath = fullPath
        standardizedFullPath = (fullPath as NSString).standardizingPath
        self.parentFolderID = parentFolderID
        self.modificationDate = modificationDate
    }
}

package struct ResolvedWorkspaceSelection: Equatable {
    package let files: [WorkspaceFileRecord]
    package let folders: [WorkspaceFolderRecord]
    package let missingPaths: [String]

    package init(files: [WorkspaceFileRecord], folders: [WorkspaceFolderRecord], missingPaths: [String]) {
        self.files = files
        self.folders = folders
        self.missingPaths = missingPaths
    }
}

package struct ResolvedPromptFileEntry: Identifiable, Equatable {
    package let id: ResolvedPromptFileEntryID
    package let file: WorkspaceFileRecord
    package let isCodemap: Bool
    package let lineRanges: [LineRange]?
    package let mode: PromptFileEntryMode
    package let loadedContent: String?
    package let rootFolderPath: String?
    package let role: ResolvedPromptFileEntryRole

    package init(
        file: WorkspaceFileRecord,
        isCodemap: Bool = false,
        lineRanges: [LineRange]? = nil,
        mode: PromptFileEntryMode = .fullFile,
        loadedContent: String? = nil,
        rootFolderPath: String? = nil,
        role: ResolvedPromptFileEntryRole = .ordinary
    ) {
        id = ResolvedPromptFileEntryID(fileID: file.id, mode: mode, lineRanges: lineRanges)
        self.file = file
        self.isCodemap = isCodemap
        self.lineRanges = lineRanges
        self.mode = mode
        self.loadedContent = loadedContent
        self.rootFolderPath = rootFolderPath
        self.role = role
    }
}

package enum ResolvedPromptFileEntryRole: Equatable {
    case ordinary
    case authorizedGitDiffArtifact
}

package struct ResolvedPromptFileBlockRecord: Equatable {
    package let entry: ResolvedPromptFileEntry
    package let file: WorkspaceFileRecord
    package let text: String
    package let isCodemap: Bool

    package init(entry: ResolvedPromptFileEntry, file: WorkspaceFileRecord, text: String, isCodemap: Bool) {
        self.entry = entry
        self.file = file
        self.text = text
        self.isCodemap = isCodemap
    }
}

package struct ResolvedPromptFileEntryID: Hashable {
    package let fileID: UUID
    package let mode: PromptFileEntryMode
    package let lineRanges: [LineRange]?

    package init(fileID: UUID, mode: PromptFileEntryMode, lineRanges: [LineRange]?) {
        self.fileID = fileID
        self.mode = mode
        self.lineRanges = lineRanges
    }
}

package enum PromptFileEntryMode: Hashable {
    case fullFile
    case sliced
    case codemap
}

package struct WorkspaceCodemapSnapshot {
    package let fileID: UUID
    package let rootID: UUID
    package let rootPath: String
    package let relativePath: String
    package let fullPath: String
    package let modificationDate: Date
    package let fileAPI: FileAPI?

    package init(
        fileID: UUID,
        rootID: UUID,
        rootPath: String,
        relativePath: String,
        fullPath: String,
        modificationDate: Date,
        fileAPI: FileAPI?
    ) {
        self.fileID = fileID
        self.rootID = rootID
        self.rootPath = rootPath
        self.relativePath = relativePath
        self.fullPath = fullPath
        self.modificationDate = modificationDate
        self.fileAPI = fileAPI
    }
}

// Immutable codemap state captured once for a context-building operation.
// Consumers keep using this value even if the workspace store changes across awaits.

package struct WorkspaceCodemapSnapshotBundle {
    package struct RenderedCodemap {
        package let text: String
        package let tokenCount: Int

        package init(text: String, tokenCount: Int) {
            self.text = text
            self.tokenCount = tokenCount
        }
    }

    package static let empty = WorkspaceCodemapSnapshotBundle(snapshots: [])

    package let snapshotsByFileID: [UUID: WorkspaceCodemapSnapshot]
    package let orderedSnapshots: [WorkspaceCodemapSnapshot]

    package init(snapshots: [WorkspaceCodemapSnapshot]) {
        orderedSnapshots = snapshots.sorted {
            let lhsPath = StandardizedPath.absolute($0.fullPath)
            let rhsPath = StandardizedPath.absolute($1.fullPath)
            if lhsPath != rhsPath { return lhsPath < rhsPath }
            return $0.fileID.uuidString < $1.fileID.uuidString
        }
        snapshotsByFileID = Dictionary(uniqueKeysWithValues: orderedSnapshots.map { ($0.fileID, $0) })
    }

    package init(snapshotsByFileID: [UUID: WorkspaceCodemapSnapshot]) {
        self.init(snapshots: Array(snapshotsByFileID.values))
    }

    package var count: Int {
        snapshotsByFileID.count
    }

    package func snapshot(for file: WorkspaceFileRecord) -> WorkspaceCodemapSnapshot? {
        guard let snapshot = snapshotsByFileID[file.id],
              snapshot.rootID == file.rootID,
              StandardizedPath.absolute(snapshot.fullPath) == file.standardizedFullPath
        else { return nil }
        return snapshot
    }

    package func hasRenderableCodemap(for file: WorkspaceFileRecord) -> Bool {
        snapshot(for: file)?.fileAPI != nil
    }
}

package struct WorkspaceCodemapRepairResult {
    package let snapshotsByFileID: [UUID: WorkspaceCodemapSnapshot]
    package let pendingFileIDs: Set<UUID>

    package init(snapshotsByFileID: [UUID: WorkspaceCodemapSnapshot], pendingFileIDs: Set<UUID>) {
        self.snapshotsByFileID = snapshotsByFileID
        self.pendingFileIDs = pendingFileIDs
    }
}

package struct WorkspaceCodemapUpdateEvent {
    package let rootID: UUID
    package let rootPath: String
    package let snapshots: [WorkspaceCodemapSnapshot]
    package let removedFileIDs: [UUID]
    package let isRootUnload: Bool

    package init(
        rootID: UUID,
        rootPath: String,
        snapshots: [WorkspaceCodemapSnapshot],
        removedFileIDs: [UUID] = [],
        isRootUnload: Bool = false
    ) {
        self.rootID = rootID
        self.rootPath = rootPath
        self.snapshots = snapshots
        self.removedFileIDs = removedFileIDs
        self.isRootUnload = isRootUnload
    }
}

package struct WorkspacePathLookupRequest: Equatable {
    package let userPath: String
    package let profile: PathLocateProfile
    package let rootScope: WorkspaceLookupRootScope
    package let selectedFileFullPaths: Set<String>

    package init(
        userPath: String,
        profile: PathLocateProfile = .uiAssisted,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        selectedFileFullPaths: Set<String> = []
    ) {
        self.userPath = userPath
        self.profile = profile
        self.rootScope = rootScope
        self.selectedFileFullPaths = selectedFileFullPaths
    }
}

package struct WorkspacePathLocation: Equatable, Hashable {
    package let rootID: UUID
    package let rootPath: String
    package let correctedPath: String

    package init(rootID: UUID, rootPath: String, correctedPath: String) {
        self.rootID = rootID
        self.rootPath = rootPath
        self.correctedPath = correctedPath
    }

    package var absolutePath: String {
        let standardizedRoot = (rootPath as NSString).standardizingPath
        if correctedPath.hasPrefix("/") {
            return (correctedPath as NSString).standardizingPath
        }
        return ((standardizedRoot as NSString).appendingPathComponent(correctedPath) as NSString).standardizingPath
    }
}

package struct WorkspacePathLookupResult: Equatable {
    package let input: String
    package let location: WorkspacePathLocation
    package let file: WorkspaceFileRecord?
    package let folder: WorkspaceFolderRecord?

    package init(input: String, location: WorkspacePathLocation, file: WorkspaceFileRecord?, folder: WorkspaceFolderRecord?) {
        self.input = input
        self.location = location
        self.file = file
        self.folder = folder
    }
}

import Foundation

package extension WorkspaceCodemapSnapshotBundle {
    func renderedCodemap(for file: WorkspaceFileRecord, displayPath: String) -> RenderedCodemap? {
        guard let api = snapshot(for: file)?.fileAPI else { return nil }
        let text = api.getFullAPIDescription(displayPath: displayPath)
        guard !text.isEmpty else { return nil }
        return RenderedCodemap(
            text: text,
            tokenCount: TokenEstimator.estimateTokens(for: text)
        )
    }
}

package enum WorkspaceSearchCatalogAccess: Equatable {
    case available(WorkspaceSearchCatalogSnapshot)
    case unavailable(WorkspaceLookupRootScopeAvailability)
}

package enum WorkspaceExactPathLookupKind: Hashable {
    case file
    case folder
    case either
}

package struct WorkspaceFolderExpansionResult: Equatable {
    package let files: [WorkspaceFileRecord]
    package let handled: Bool
    package let displayPath: String?
    package let issue: PathResolutionIssue?
}

package final class WorkspaceSearchCatalogGenerationLease: @unchecked Sendable {
    private let retainedObjects: [AnyObject]

    init(retaining retainedObjects: [AnyObject]) {
        self.retainedObjects = retainedObjects
    }
}

package struct WorkspaceSearchCatalogSnapshot: Equatable {
    package let generation: UInt64
    let rootScope: WorkspaceLookupRootScope
    package let roots: [WorkspaceRootRecord]
    package let files: [WorkspaceFileRecord]
    package let entries: [WorkspaceSearchCatalogEntry]
    package let rootPathIndexes: [WorkspaceSearchRootPathIndex]
    package let diagnostics: WorkspaceCatalogDiagnostics
    private let generationLease: WorkspaceSearchCatalogGenerationLease?

    init(
        generation: UInt64,
        rootScope: WorkspaceLookupRootScope,
        roots: [WorkspaceRootRecord],
        files: [WorkspaceFileRecord],
        entries: [WorkspaceSearchCatalogEntry],
        rootPathIndexes: [WorkspaceSearchRootPathIndex] = [],
        diagnostics: WorkspaceCatalogDiagnostics,
        generationLease: WorkspaceSearchCatalogGenerationLease? = nil
    ) {
        self.generation = generation
        self.rootScope = rootScope
        self.roots = roots
        self.files = files
        self.entries = entries
        self.rootPathIndexes = rootPathIndexes
        self.diagnostics = diagnostics
        self.generationLease = generationLease
    }

    func recordsOnlyProjection() -> WorkspaceSearchCatalogSnapshot {
        guard !rootPathIndexes.isEmpty else { return self }
        return WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: rootScope,
            roots: roots,
            files: files,
            entries: entries,
            diagnostics: diagnostics,
            generationLease: generationLease
        )
    }

    package static func == (lhs: WorkspaceSearchCatalogSnapshot, rhs: WorkspaceSearchCatalogSnapshot) -> Bool {
        lhs.generation == rhs.generation
            && lhs.rootScope == rhs.rootScope
            && lhs.roots == rhs.roots
            && lhs.files == rhs.files
            && lhs.entries == rhs.entries
            && lhs.diagnostics == rhs.diagnostics
    }
}

package struct WorkspaceDirectFolderChildrenSnapshot: Equatable {
    package let generation: UInt64
    package let root: WorkspaceRootRecord
    package let folder: WorkspaceFolderRecord
    package let childFolders: [WorkspaceFolderRecord]
    package let childFiles: [WorkspaceFileRecord]

    var isEmpty: Bool {
        childFolders.isEmpty && childFiles.isEmpty
    }
}

package struct WorkspaceExternalReadableFile: Equatable, Hashable {
    package let absolutePath: String
    package let displayPath: String

    package init(absolutePath: String, displayPath: String) {
        self.absolutePath = absolutePath
        self.displayPath = displayPath
    }
}

package enum WorkspaceReadableFileHandle: Equatable {
    case workspace(WorkspaceFileRecord)
    case external(WorkspaceExternalReadableFile)
}

package struct WorkspaceFileSystemDeltaEvent: Equatable {
    package let rootID: UUID
    package let rootPath: String
    package let delta: FileSystemDelta
}

package struct WorkspaceIngressBarrierSample: Equatable {
    package let rootID: UUID
    package let rootPath: String
    package let pendingRawEventCountBeforeFlush: Int
    package let acceptedWatcherWatermark: UInt64
    package let publishedServicePublicationSequence: UInt64
    package let appliedServicePublicationSequence: UInt64
    package let appliedWatcherWatermark: UInt64
}

package struct WorkspaceAppliedIndexRootSnapshot: Equatable {
    package let root: WorkspaceRootRecord
    package let generation: UInt64
    package let files: [WorkspaceFileRecord]
    package let folders: [WorkspaceFolderRecord]
}

package struct WorkspaceSliceRebasePathState: Equatable {
    package let rootID: UUID
    package let rootLifetimeID: UUID
    package let rootKind: WorkspaceRootKind
    package let appliedIndexGeneration: UInt64
}

package struct WorkspaceSliceRebaseSourceSnapshot: Equatable {
    package let rootID: UUID
    package let rootLifetimeID: UUID
    package let fileID: UUID
    package let relativePath: String
    package let fullPath: String
    package let text: String
    package let modificationTime: Double
}

package struct WorkspaceAppliedIndexBatchEvent: Equatable {
    package let rootID: UUID
    package let rootPath: String
    package let generation: UInt64
    package let rootLifetimeID: UUID?
    package let modifiedFileSourceSnapshotsByID: [UUID: WorkspaceSliceRebaseSourceSnapshot]
    package let upsertedFiles: [WorkspaceFileRecord]
    package let upsertedFolders: [WorkspaceFolderRecord]
    package let removedFileIDs: [UUID]
    package let removedFolderIDs: [UUID]
    package let removedFilePaths: [String]
    package let removedFolderPaths: [String]
    package let modifiedFileIDs: [UUID]
    package let modifiedFolderIDs: [UUID]
    package let requiresFullResync: Bool
    package let isRootUnload: Bool

    package init(
        rootID: UUID,
        rootPath: String,
        generation: UInt64,
        rootLifetimeID: UUID? = nil,
        modifiedFileSourceSnapshotsByID: [UUID: WorkspaceSliceRebaseSourceSnapshot] = [:],
        upsertedFiles: [WorkspaceFileRecord] = [],
        upsertedFolders: [WorkspaceFolderRecord] = [],
        removedFileIDs: [UUID] = [],
        removedFolderIDs: [UUID] = [],
        removedFilePaths: [String] = [],
        removedFolderPaths: [String] = [],
        modifiedFileIDs: [UUID] = [],
        modifiedFolderIDs: [UUID] = [],
        requiresFullResync: Bool = false,
        isRootUnload: Bool = false
    ) {
        self.rootID = rootID
        self.rootPath = rootPath
        self.generation = generation
        self.rootLifetimeID = rootLifetimeID
        self.modifiedFileSourceSnapshotsByID = modifiedFileSourceSnapshotsByID
        self.upsertedFiles = upsertedFiles
        self.upsertedFolders = upsertedFolders
        self.removedFileIDs = removedFileIDs
        self.removedFolderIDs = removedFolderIDs
        self.removedFilePaths = removedFilePaths
        self.removedFolderPaths = removedFolderPaths
        self.modifiedFileIDs = modifiedFileIDs
        self.modifiedFolderIDs = modifiedFolderIDs
        self.requiresFullResync = requiresFullResync
        self.isRootUnload = isRootUnload
    }
}
