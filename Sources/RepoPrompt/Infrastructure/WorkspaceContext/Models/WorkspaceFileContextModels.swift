import Foundation

/// Root scopes shared by UI and headless workspace file lookup paths.
enum WorkspaceLookupRootScope: Hashable {
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

enum WorkspaceLookupRootScopeAvailability: Equatable {
    case available
    case sessionWorktreeUnavailable(missingPhysicalRootPaths: [String])
}

enum WorkspaceSearchCatalogAccess: Equatable {
    case available(WorkspaceSearchCatalogSnapshot)
    case unavailable(WorkspaceLookupRootScopeAvailability)
}

typealias LookupRootScope = WorkspaceLookupRootScope

enum WorkspaceRootKind: Hashable {
    case primaryWorkspace
    case workspaceGitData
    case supplementalSystem
    case sessionWorktree
}

enum WorkspaceExactPathLookupKind: Hashable {
    case file
    case folder
    case either
}

struct WorkspaceFolderExpansionResult: Equatable {
    let files: [WorkspaceFileRecord]
    let handled: Bool
    let displayPath: String?
    let issue: PathResolutionIssue?
}

struct WorkspaceRootLoadFailure: Equatable, Identifiable {
    let id: UUID
    let rootPath: String
    let standardizedRootPath: String
    let kind: WorkspaceRootKind
    let errorDescription: String

    init(id: UUID = UUID(), rootPath: String, kind: WorkspaceRootKind, errorDescription: String) {
        self.id = id
        self.rootPath = rootPath
        standardizedRootPath = StandardizedPath.absolute(rootPath)
        self.kind = kind
        self.errorDescription = errorDescription
    }

    static func == (lhs: WorkspaceRootLoadFailure, rhs: WorkspaceRootLoadFailure) -> Bool {
        lhs.standardizedRootPath == rhs.standardizedRootPath &&
            lhs.kind == rhs.kind &&
            lhs.errorDescription == rhs.errorDescription
    }
}

struct WorkspaceSearchReadinessTicket: Equatable, Hashable {
    let workspaceID: UUID?
    let generation: UInt64
}

enum WorkspaceSearchReadinessWaitError: Error, Equatable {
    case unavailable
    case timedOut
    case superseded
}

enum WorkspaceSearchReadinessState: Equatable {
    case idle
    case activating(workspaceID: UUID?, generation: UInt64)
    case loadingCatalog(workspaceID: UUID?, generation: UInt64, loadedRootCount: Int, expectedRootCount: Int, failures: [WorkspaceRootLoadFailure])
    case buildingIndexes(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64, failures: [WorkspaceRootLoadFailure])
    case ready(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64, indexedGeneration: UInt64, diagnostics: WorkspaceCatalogDiagnostics)
    case degraded(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64?, indexedGeneration: UInt64?, failures: [WorkspaceRootLoadFailure], diagnostics: WorkspaceCatalogDiagnostics?)

    var ticket: WorkspaceSearchReadinessTicket? {
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

    var isSearchAdmissible: Bool {
        switch self {
        case .ready, .degraded:
            true
        case .idle, .activating, .loadingCatalog, .buildingIndexes:
            false
        }
    }
}

struct WorkspaceCatalogDiagnostics: Equatable {
    let generation: UInt64
    let rootScope: WorkspaceLookupRootScope
    let rootCount: Int
    let folderCount: Int
    let fileCount: Int
    let totalItemCount: Int

    init(
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

struct WorkspaceSearchCatalogEntry: Identifiable, Equatable, Hashable {
    let id: UUID
    let rootID: UUID
    let rootPath: String
    let rootName: String
    let name: String
    let relativePath: String
    let standardizedRelativePath: String
    let fullPath: String
    let standardizedFullPath: String
    let displayPath: String

    init(file: WorkspaceFileRecord, root: WorkspaceRootRecord, displayPath: String? = nil) {
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

/// Opaque ARC lease keeping immutable catalog generations alive for snapshot readers.
final class WorkspaceSearchCatalogGenerationLease: @unchecked Sendable {
    private let retainedObjects: [AnyObject]

    init(retaining retainedObjects: [AnyObject]) {
        self.retainedObjects = retainedObjects
    }
}

enum WorkspaceSearchCatalogAccessRequirement: Equatable {
    case recordsOnly
    case recordsAndPathIndexes

    func satisfies(_ requirement: WorkspaceSearchCatalogAccessRequirement) -> Bool {
        switch (self, requirement) {
        case (.recordsAndPathIndexes, _), (.recordsOnly, .recordsOnly):
            true
        case (.recordsOnly, .recordsAndPathIndexes):
            false
        }
    }

    var requiresPathIndexes: Bool {
        self == .recordsAndPathIndexes
    }
}

struct WorkspaceSearchCatalogSnapshot: Equatable {
    let generation: UInt64
    let rootScope: WorkspaceLookupRootScope
    let roots: [WorkspaceRootRecord]
    let files: [WorkspaceFileRecord]
    let entries: [WorkspaceSearchCatalogEntry]
    let rootPathIndexes: [WorkspaceSearchRootPathIndex]
    let diagnostics: WorkspaceCatalogDiagnostics
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

    static func == (lhs: WorkspaceSearchCatalogSnapshot, rhs: WorkspaceSearchCatalogSnapshot) -> Bool {
        lhs.generation == rhs.generation
            && lhs.rootScope == rhs.rootScope
            && lhs.roots == rhs.roots
            && lhs.files == rhs.files
            && lhs.entries == rhs.entries
            && lhs.diagnostics == rhs.diagnostics
    }
}

struct WorkspaceDirectFolderChildrenSnapshot: Equatable {
    let generation: UInt64
    let root: WorkspaceRootRecord
    let folder: WorkspaceFolderRecord
    let childFolders: [WorkspaceFolderRecord]
    let childFiles: [WorkspaceFileRecord]

    var isEmpty: Bool {
        childFolders.isEmpty && childFiles.isEmpty
    }
}

struct WorkspaceSearchQueryResult: Equatable {
    let query: String
    let indexedGeneration: UInt64?
    let snapshotGeneration: UInt64?
    let pendingGeneration: UInt64?
    let observedGeneration: UInt64?
    let results: [WorkspaceSearchCatalogEntry]
    let isIndexReady: Bool
    let isStale: Bool

    init(
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

struct WorkspaceResolvedCandidates: Equatable {
    let candidates: [WorkspaceFileRecord]
    let resolvedMap: [String: String]
    let invalidPaths: [String]
}

struct WorkspaceCodemapOnlyCandidates: Equatable {
    let candidates: [WorkspaceFileRecord]
    let resolvedMap: [String: String]
    let invalidPaths: [String]
    let codemapUnavailable: [String]
}

struct WorkspaceRootRecord: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let fullPath: String
    let standardizedFullPath: String
    let isSystemRoot: Bool
    let kind: WorkspaceRootKind

    init(id: UUID = UUID(), name: String, fullPath: String, isSystemRoot: Bool = false) {
        self.init(
            id: id,
            name: name,
            fullPath: fullPath,
            kind: isSystemRoot ? .supplementalSystem : .primaryWorkspace,
            isSystemRoot: isSystemRoot
        )
    }

    init(id: UUID = UUID(), name: String, fullPath: String, kind: WorkspaceRootKind) {
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

struct WorkspaceFolderRecord: Identifiable, Equatable, Hashable {
    let id: UUID
    let rootID: UUID
    let name: String
    let relativePath: String
    let standardizedRelativePath: String
    let fullPath: String
    let standardizedFullPath: String
    let parentFolderID: UUID?
    let modificationDate: Date?

    init(
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

struct WorkspaceFileRecord: Identifiable, Equatable, Hashable {
    let id: UUID
    let rootID: UUID
    let name: String
    let relativePath: String
    let standardizedRelativePath: String
    let fullPath: String
    let standardizedFullPath: String
    let parentFolderID: UUID?
    let modificationDate: Date?

    init(
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

struct ResolvedWorkspaceSelection: Equatable {
    let files: [WorkspaceFileRecord]
    let folders: [WorkspaceFolderRecord]
    let missingPaths: [String]
}

struct ResolvedPromptFileEntry: Identifiable, Equatable {
    let id: ResolvedPromptFileEntryID
    let file: WorkspaceFileRecord
    let isCodemap: Bool
    let lineRanges: [LineRange]?
    let mode: PromptFileEntryMode
    let loadedContent: String?
    let rootFolderPath: String?
    let role: ResolvedPromptFileEntryRole

    init(
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

enum ResolvedPromptFileEntryRole: Equatable {
    case ordinary
    case authorizedGitDiffArtifact
}

struct ResolvedPromptFileBlockRecord: Equatable {
    let entry: ResolvedPromptFileEntry
    let file: WorkspaceFileRecord
    let text: String
    let isCodemap: Bool
}

struct ResolvedPromptFileEntryID: Hashable {
    let fileID: UUID
    let mode: PromptFileEntryMode
    let lineRanges: [LineRange]?
}

enum PromptFileEntryMode: Hashable {
    case fullFile
    case sliced
    case codemap
}

struct WorkspaceExternalReadableFile: Equatable, Hashable {
    let absolutePath: String
    let displayPath: String
}

enum WorkspaceReadableFileHandle: Equatable {
    case workspace(WorkspaceFileRecord)
    case external(WorkspaceExternalReadableFile)
}

struct WorkspaceFileSystemDeltaEvent: Equatable {
    let rootID: UUID
    let rootPath: String
    let delta: FileSystemDelta
}

struct WorkspaceIngressBarrierSample: Equatable {
    let rootID: UUID
    let rootPath: String
    let pendingRawEventCountBeforeFlush: Int
    let acceptedWatcherWatermark: UInt64
    let publishedServicePublicationSequence: UInt64
    let appliedServicePublicationSequence: UInt64
    let appliedWatcherWatermark: UInt64
}

struct WorkspaceAppliedIndexRootSnapshot: Equatable {
    let root: WorkspaceRootRecord
    let generation: UInt64
    let files: [WorkspaceFileRecord]
    let folders: [WorkspaceFolderRecord]
}

struct WorkspaceSliceRebasePathState: Equatable {
    let rootID: UUID
    let rootLifetimeID: UUID
    let rootKind: WorkspaceRootKind
    let appliedIndexGeneration: UInt64
}

struct WorkspaceSliceRebaseSourceSnapshot: Equatable {
    let rootID: UUID
    let rootLifetimeID: UUID
    let fileID: UUID
    let relativePath: String
    let fullPath: String
    let text: String
    let modificationTime: Double
}

struct WorkspaceAppliedIndexBatchEvent: Equatable {
    let rootID: UUID
    let rootPath: String
    let generation: UInt64
    let rootLifetimeID: UUID?
    let modifiedFileSourceSnapshotsByID: [UUID: WorkspaceSliceRebaseSourceSnapshot]
    let upsertedFiles: [WorkspaceFileRecord]
    let upsertedFolders: [WorkspaceFolderRecord]
    let removedFileIDs: [UUID]
    let removedFolderIDs: [UUID]
    let removedFilePaths: [String]
    let removedFolderPaths: [String]
    let modifiedFileIDs: [UUID]
    let modifiedFolderIDs: [UUID]
    let requiresFullResync: Bool
    let isRootUnload: Bool

    init(
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

struct WorkspacePathLookupRequest: Equatable {
    let userPath: String
    let profile: PathLocateProfile
    let rootScope: WorkspaceLookupRootScope
    let selectedFileFullPaths: Set<String>

    init(
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

struct WorkspacePathLocation: Equatable, Hashable {
    let rootID: UUID
    let rootPath: String
    let correctedPath: String

    var absolutePath: String {
        let standardizedRoot = (rootPath as NSString).standardizingPath
        if correctedPath.hasPrefix("/") {
            return (correctedPath as NSString).standardizingPath
        }
        return ((standardizedRoot as NSString).appendingPathComponent(correctedPath) as NSString).standardizingPath
    }
}

struct WorkspacePathLookupResult: Equatable {
    let input: String
    let location: WorkspacePathLocation
    let file: WorkspaceFileRecord?
    let folder: WorkspaceFolderRecord?
}
