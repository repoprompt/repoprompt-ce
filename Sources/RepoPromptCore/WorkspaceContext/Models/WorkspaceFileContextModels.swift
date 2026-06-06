import Foundation

/// Root scopes shared by UI and headless workspace file lookup paths.
package enum WorkspaceLookupRootScope: Hashable {
    case visibleWorkspace
    case visibleWorkspacePlusGitData
    case allLoaded
    case sessionBoundWorkspace(logicalRootPaths: Set<String>, physicalRootPaths: Set<String>)
}

package typealias LookupRootScope = WorkspaceLookupRootScope

package enum WorkspaceRootKind: Hashable {
    case primaryWorkspace
    case workspaceGitData
    case supplementalSystem
    case sessionWorktree
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

package enum WorkspaceSearchReadinessState: Equatable {
    case idle
    case activating(workspaceID: UUID?, generation: UInt64)
    case loadingCatalog(workspaceID: UUID?, generation: UInt64, loadedRootCount: Int, expectedRootCount: Int, failures: [WorkspaceRootLoadFailure])
    case buildingIndexes(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64, failures: [WorkspaceRootLoadFailure])
    case ready(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64, indexedGeneration: UInt64, diagnostics: WorkspaceCatalogDiagnostics)
    case degraded(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64?, indexedGeneration: UInt64?, failures: [WorkspaceRootLoadFailure], diagnostics: WorkspaceCatalogDiagnostics?)
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

package struct WorkspaceSearchCatalogSnapshot: Equatable {
    package let generation: UInt64
    package let rootScope: WorkspaceLookupRootScope
    package let roots: [WorkspaceRootRecord]
    package let files: [WorkspaceFileRecord]
    package let entries: [WorkspaceSearchCatalogEntry]
    package let diagnostics: WorkspaceCatalogDiagnostics
}

/// Immutable store-owned inputs captured for later workspace projection composition.
///
/// File identities, selection resolution, codemap state, and the file tree are coherent at
/// `provenance.captureGeneration`. File contents are intentionally excluded and may be read live later.
package struct WorkspaceFileContextCapture {
    package struct Provenance: Equatable {
        package let captureGeneration: UInt64
        package let catalogGeneration: UInt64
        package let catalogValidationToken: UInt64
        package let rootScope: WorkspaceLookupRootScope
        package let ingressSamples: [WorkspaceIngressBarrierSample]
    }

    package struct SelectionPath: Equatable {
        package enum Resolution: Equatable {
            case file(WorkspaceFileRecord)
            case folder(WorkspaceFolderRecord, descendantFiles: [WorkspaceFileRecord])
            case unresolved(PathResolutionIssue)
        }

        package let input: String
        package let resolution: Resolution
    }

    package struct Slice: Equatable {
        package let path: String
        package let ranges: [LineRange]
        package let file: WorkspaceFileRecord?
        package let issue: PathResolutionIssue?
    }

    package let provenance: Provenance
    package let storedSelection: StoredSelection
    package let selectedPaths: [SelectionPath]
    package let autoCodemapPaths: [SelectionPath]
    package let slices: [Slice]
    package let catalog: WorkspaceSearchCatalogSnapshot
    package let materializedFolders: [WorkspaceFolderRecord]
    package let materializedFiles: [WorkspaceFileRecord]
    package let codemapSnapshots: [WorkspaceCodemapSnapshot]
    package let fileTree: FileTreeSelectionSnapshot
}

package struct WorkspaceDirectFolderChildrenSnapshot: Equatable {
    package let generation: UInt64
    package let root: WorkspaceRootRecord
    package let folder: WorkspaceFolderRecord
    package let childFolders: [WorkspaceFolderRecord]
    package let childFiles: [WorkspaceFileRecord]

    package var isEmpty: Bool {
        childFolders.isEmpty && childFiles.isEmpty
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
}

package struct ResolvedPromptFileEntry: Identifiable, Equatable {
    package let id: ResolvedPromptFileEntryID
    package let file: WorkspaceFileRecord
    package let isCodemap: Bool
    package let lineRanges: [LineRange]?
    package let mode: PromptFileEntryMode
    package let loadedContent: String?
    package let rootFolderPath: String?

    package init(
        file: WorkspaceFileRecord,
        isCodemap: Bool = false,
        lineRanges: [LineRange]? = nil,
        mode: PromptFileEntryMode = .fullFile,
        loadedContent: String? = nil,
        rootFolderPath: String? = nil
    ) {
        id = ResolvedPromptFileEntryID(fileID: file.id, mode: mode, lineRanges: lineRanges)
        self.file = file
        self.isCodemap = isCodemap
        self.lineRanges = lineRanges
        self.mode = mode
        self.loadedContent = loadedContent
        self.rootFolderPath = rootFolderPath
    }
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
}

package enum PromptFileEntryMode: Hashable {
    case fullFile
    case sliced
    case codemap
}

package struct WorkspaceExternalReadableFile: Equatable, Hashable {
    package let absolutePath: String
    package let displayPath: String
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

package struct WorkspaceAppliedIndexBatchEvent: Equatable {
    package let rootID: UUID
    package let rootPath: String
    package let generation: UInt64
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

package struct WorkspaceCodemapSnapshot {
    package let fileID: UUID
    package let rootID: UUID
    package let rootPath: String
    package let relativePath: String
    package let fullPath: String
    package let modificationDate: Date
    package let fileAPI: FileAPI?
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
}
