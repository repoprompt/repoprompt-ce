import Foundation
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptWorkspaceCore

/// Root scopes shared by UI and headless workspace file lookup paths.
package enum WorkspaceLookupRootScope: Hashable {
    case visibleWorkspace
    case visibleWorkspacePlusGitData
    case allLoaded
    case allLoadedExcludingGitData
    case sessionBoundWorkspace(canonicalRootPaths: Set<String>, physicalRootPaths: Set<String>)
    case validatedSessionBoundWorkspace(
        canonicalRoots: Set<WorkspaceRootRef>,
        physicalRoots: Set<WorkspaceRootRef>,
        includesGitData: Bool = false
    )
}

package enum WorkspaceLookupRootSelectorConflict: Error, Equatable {
    case rootIDHasMultiplePaths
    case rootIDHasMultipleRoles
}

package struct WorkspaceValidatedLookupRootSelector: Equatable {
    package let canonicalRootPathsByID: [UUID: String]
    package let physicalRootPathsByID: [UUID: String]
}

package enum WorkspaceLookupRootSelectorValidation: Equatable {
    case valid(WorkspaceValidatedLookupRootSelector)
    case conflict(WorkspaceLookupRootSelectorConflict)
}

package enum WorkspaceLookupRootSelectorValidator {
    package static func validate(
        canonicalRoots: Set<WorkspaceRootRef>,
        physicalRoots: Set<WorkspaceRootRef>
    ) -> WorkspaceLookupRootSelectorValidation {
        switch normalizedPathsByID(canonicalRoots) {
        case let .failure(conflict):
            return .conflict(conflict)
        case let .success(canonicalRootPathsByID):
            switch normalizedPathsByID(physicalRoots) {
            case let .failure(conflict):
                return .conflict(conflict)
            case let .success(physicalRootPathsByID):
                guard Set(canonicalRootPathsByID.keys).isDisjoint(with: physicalRootPathsByID.keys) else {
                    return .conflict(.rootIDHasMultipleRoles)
                }
                return .valid(WorkspaceValidatedLookupRootSelector(
                    canonicalRootPathsByID: canonicalRootPathsByID,
                    physicalRootPathsByID: physicalRootPathsByID
                ))
            }
        }
    }

    private static func normalizedPathsByID(
        _ roots: Set<WorkspaceRootRef>
    ) -> Result<[UUID: String], WorkspaceLookupRootSelectorConflict> {
        var pathsByID: [UUID: String] = [:]
        for root in roots {
            let path = root.standardizedFullPath
            if let existingPath = pathsByID[root.id], existingPath != path {
                return .failure(.rootIDHasMultiplePaths)
            }
            pathsByID[root.id] = path
        }
        return .success(pathsByID)
    }
}

package enum WorkspaceLookupRootScopeAvailability: Equatable {
    case available
    case sessionWorktreeUnavailable(missingPhysicalRootPaths: [String])
}

package enum WorkspaceSearchCatalogAccess: Equatable {
    case available(WorkspaceSearchCatalogSnapshot)
    case unavailable(WorkspaceLookupRootScopeAvailability)
}

typealias LookupRootScope = WorkspaceLookupRootScope

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

package struct WorkspaceSearchReadinessTicket: Equatable, Hashable {
    package let workspaceID: UUID?
    package let generation: UInt64
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

    /// Root-catalog completion, which happens one state earlier than search readiness:
    /// `.buildingIndexes` already carries the catalog generation and the load failures, so
    /// every configured root is either registered or recorded as failed by then. A consumer
    /// that only needs root identities must not wait for search-index construction it never
    /// reads.
    var isRootCatalogAdmissible: Bool {
        switch self {
        case .buildingIndexes, .ready:
            true
        case let .degraded(_, _, catalogGeneration, _, _, _):
            catalogGeneration != nil
        case .idle, .activating, .loadingCatalog:
            false
        }
    }
}

/// Which completion a readiness waiter is gated on. Two consumers wait on the same state
/// machine for different things, so the admission rule travels with the waiter rather than
/// being baked into the state.
package enum WorkspaceReadinessAdmission: Equatable {
    case searchIndex
    case rootCatalog

    package func admits(_ state: WorkspaceSearchReadinessState) -> Bool {
        switch self {
        case .searchIndex:
            state.isSearchAdmissible
        case .rootCatalog:
            state.isRootCatalogAdmissible
        }
    }
}

/// Evidence that one workspace's configured roots are all loaded under one hydration
/// generation.
///
/// Deliberately carries no `Codable`/serialization conformance: the ticket and the root
/// identities are process-lifetime values, so a persisted copy would outlive the generation
/// that makes it true and would reassert loaded roots that no longer exist.
package struct WorkspaceRootCatalogSnapshot: Equatable {
    package let ticket: WorkspaceSearchReadinessTicket
    package let workspaceID: UUID
    /// Canonical, de-duplicated, workspace-declaration order.
    package let configuredRootPaths: [String]
    /// Loaded primary roots, ordered to match `configuredRootPaths`.
    package let primaryRoots: [WorkspaceRootRef]

    package init(
        ticket: WorkspaceSearchReadinessTicket,
        workspaceID: UUID,
        configuredRootPaths: [String],
        primaryRoots: [WorkspaceRootRef]
    ) {
        self.ticket = ticket
        self.workspaceID = workspaceID
        self.configuredRootPaths = configuredRootPaths
        self.primaryRoots = primaryRoots
    }

    /// A workspace that declares no roots at all. Distinct from a workspace whose roots
    /// have not been hydrated yet, which never produces a snapshot.
    package var isGenuinelyRootless: Bool {
        configuredRootPaths.isEmpty && primaryRoots.isEmpty
    }
}

/// Messages stay free of absolute root paths so a failure can be surfaced to an MCP client
/// without leaking filesystem layout.
package enum WorkspaceRootCatalogSnapshotError: LocalizedError, Equatable {
    case missingWorkspaceIdentity
    case workspaceNotActive
    case readinessUnavailable
    case readinessTimedOut
    case readinessSuperseded
    case inconsistentRootProjection

    package var errorDescription: String? {
        switch self {
        case .missingWorkspaceIdentity:
            "Workspace readiness did not identify a workspace."
        case .workspaceNotActive:
            "The requested workspace is not the active workspace."
        case .readinessUnavailable:
            "Workspace readiness is not being tracked."
        case .readinessTimedOut:
            "The workspace root catalog did not finish loading in time."
        case .readinessSuperseded:
            "Workspace hydration advanced before the root catalog could be read."
        case .inconsistentRootProjection:
            "The workspace's configured roots and loaded roots do not agree."
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

/// Opaque ARC lease keeping immutable catalog generations alive for snapshot readers.
package final class WorkspaceSearchCatalogGenerationLease: @unchecked Sendable {
    private let retainedObjects: [AnyObject]

    package init(retaining retainedObjects: [AnyObject]) {
        self.retainedObjects = retainedObjects
    }
}

package enum WorkspaceSearchCatalogAccessRequirement: Equatable {
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

package struct WorkspaceSearchCatalogSnapshot: Equatable {
    package let generation: UInt64
    package let rootScope: WorkspaceLookupRootScope
    package let roots: [WorkspaceRootRecord]
    package let files: [WorkspaceFileRecord]
    package let entries: [WorkspaceSearchCatalogEntry]
    package let rootPathIndexes: [WorkspaceSearchRootPathIndex]
    package let diagnostics: WorkspaceCatalogDiagnostics
    private let generationLease: WorkspaceSearchCatalogGenerationLease?

    package init(
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

struct WorkspaceDirectFolderChildrenSnapshot: Equatable {
    package let generation: UInt64
    package let root: WorkspaceRootRecord
    package let folder: WorkspaceFolderRecord
    let childFolders: [WorkspaceFolderRecord]
    let childFiles: [WorkspaceFileRecord]

    var isEmpty: Bool {
        childFolders.isEmpty && childFiles.isEmpty
    }
}

package struct WorkspaceSearchQueryResult: Equatable {
    let query: String
    let indexedGeneration: UInt64?
    let snapshotGeneration: UInt64?
    let pendingGeneration: UInt64?
    let observedGeneration: UInt64?
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
        standardizedFullPath = StandardizedPath.absolute(fullPath)
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
        standardizedFullPath = StandardizedPath.absolute(fullPath)
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
        standardizedFullPath = StandardizedPath.absolute(fullPath)
        self.parentFolderID = parentFolderID
        self.modificationDate = modificationDate
    }
}

package struct WorkspaceExactFileNamespace: Equatable {
    package struct RootBinding: Equatable {
        enum LookupRole: Equatable {
            case canonical
            case projectedPhysical
        }

        package let lookupRoot: WorkspaceRootRef
        let lookupRole: LookupRole
        package let clientRoots: [WorkspaceRootRef]
        let preferredClientRoot: WorkspaceRootRef
    }

    package let rootBindings: [RootBinding]
    let explicitAliasByClientRootID: [UUID: String]

    package init(rootBindings: [RootBinding]) {
        self.rootBindings = rootBindings
        let clientRoots = rootBindings.flatMap(\.clientRoots)
        explicitAliasByClientRootID = ClientPathFormatter.exactRootAliases(visibleRoots: clientRoots)
    }

    static func identity(roots: [WorkspaceRootRef]) -> WorkspaceExactFileNamespace {
        WorkspaceExactFileNamespace(
            rootBindings: roots.map {
                RootBinding(
                    lookupRoot: $0,
                    lookupRole: .canonical,
                    clientRoots: [$0],
                    preferredClientRoot: $0
                )
            }
        )
    }

    var lookupRoots: [WorkspaceRootRef] {
        rootBindings.map(\.lookupRoot)
    }

    package var clientRoots: [WorkspaceRootRef] {
        var seenPaths: Set<String> = []
        return rootBindings.flatMap(\.clientRoots).filter {
            seenPaths.insert($0.standardizedFullPath).inserted
        }
    }

    func binding(lookupRootID: UUID) -> RootBinding? {
        rootBindings.first { $0.lookupRoot.id == lookupRootID }
    }

    func explicitAlias(clientRootID: UUID) -> String? {
        explicitAliasByClientRootID[clientRootID]
    }
}

package struct WorkspaceExactExistingFileMatch: Equatable {
    package let file: WorkspaceFileRecord
    package let canonicalPath: String
}

package struct WorkspaceExactDirectoryMatch: Equatable {
    package let lookupRoot: WorkspaceRootRef
    package let relativePath: String
    package let displayPath: String
}

package enum WorkspaceExactExistingFileResolution: Equatable {
    case matched(WorkspaceExactExistingFileMatch)
    case directory(WorkspaceExactDirectoryMatch)
    case issue(PathResolutionIssue)
    case claimedMissing
    case noCandidate
}

struct ResolvedWorkspaceSelection: Equatable {
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
    package init(
        entry: ResolvedPromptFileEntry,
        file: WorkspaceFileRecord,
        text: String,
        isCodemap: Bool
    ) {
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
    let acceptedWatcherWatermark: UInt64
    let publishedServicePublicationSequence: UInt64
    let appliedServicePublicationSequence: UInt64
    let appliedWatcherWatermark: UInt64
}

package struct WorkspaceAppliedIndexRootSnapshot: Equatable {
    package let root: WorkspaceRootRecord
    package let generation: UInt64
    package let files: [WorkspaceFileRecord]
    package let folders: [WorkspaceFolderRecord]
}

package struct WorkspaceAppliedIndexRecordLookup: Equatable {
    package let root: WorkspaceRootRecord
    package let generation: UInt64
    package let filesByID: [UUID: WorkspaceFileRecord]
    package let foldersByID: [UUID: WorkspaceFolderRecord]
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

enum WorkspaceSearchCatalogChangeKind: Equatable {
    case rootLoaded
    case rootUnloaded
    case appliedIndex

    /// The catalog generation advanced without changing the discoverable search projection.
    case generationAdvancedWithoutProjectionChange
}

struct WorkspaceSearchCatalogChangeEvent: Equatable {
    package let rootID: UUID
    package let rootPath: String
    package let rootLifetimeID: UUID?
    let rootAppliedIndexGeneration: UInt64?
    let catalogGeneration: UInt64?
    package let kind: WorkspaceSearchCatalogChangeKind

    package init(
        rootID: UUID,
        rootPath: String,
        rootLifetimeID: UUID?,
        rootAppliedIndexGeneration: UInt64?,
        catalogGeneration: UInt64? = nil,
        kind: WorkspaceSearchCatalogChangeKind
    ) {
        self.rootID = rootID
        self.rootPath = rootPath
        self.rootLifetimeID = rootLifetimeID
        self.rootAppliedIndexGeneration = rootAppliedIndexGeneration
        self.catalogGeneration = catalogGeneration
        self.kind = kind
    }

    func stamped(catalogGeneration: UInt64) -> Self {
        Self(
            rootID: rootID,
            rootPath: rootPath,
            rootLifetimeID: rootLifetimeID,
            rootAppliedIndexGeneration: rootAppliedIndexGeneration,
            catalogGeneration: catalogGeneration,
            kind: kind
        )
    }
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

package struct WorkspacePathLookupRequest: Equatable {
    let userPath: String
    let profile: PathLocateProfile
    package let rootScope: WorkspaceLookupRootScope
    let selectedFileFullPaths: Set<String>

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
    let input: String
    package let location: WorkspacePathLocation
    package let file: WorkspaceFileRecord?
    package let folder: WorkspaceFolderRecord?
}

/// Transient accepted root intent. Invalid entries are counted, never silently authorized away.
package struct WorkspacePrimaryRootManifest: Equatable {
    package let orderedPaths: [String]
    package let invalidEntryCount: Int

    package init(normalizedPaths: [String?]) {
        var seen = Set<String>()
        orderedPaths = normalizedPaths.compactMap(\.self).filter { seen.insert($0).inserted }
        invalidEntryCount = normalizedPaths.count(where: { $0 == nil })
    }
}

package struct WorkspaceRootReconciliationTicket: Hashable {
    package let workspaceID: UUID
    package let activationGeneration: UInt64
    package let rootIntentGeneration: UInt64
    package init(
        workspaceID: UUID,
        activationGeneration: UInt64,
        rootIntentGeneration: UInt64
    ) {
        self.workspaceID = workspaceID
        self.activationGeneration = activationGeneration
        self.rootIntentGeneration = rootIntentGeneration
    }
}

package struct WorkspacePrimaryRootSnapshot: Equatable {
    package let ticket: WorkspaceRootReconciliationTicket
    package let roots: [WorkspaceRootRef]
    package init(
        ticket: WorkspaceRootReconciliationTicket,
        roots: [WorkspaceRootRef]
    ) {
        self.ticket = ticket
        self.roots = roots
    }
}

package struct WorkspaceRootReadinessFailure: Error, Equatable {
    package enum Availability: String {
        case missingDirectory, notDirectory, accessDenied, loadFailed
    }

    package enum Reason: Equatable {
        case emptyConfiguration, invalidConfiguration, workspaceUnavailable, workspaceInactive
        case rootsChanging, rootsUnavailable(Availability), wrongRootKind, incompleteProjection, staleInvocation
    }

    package let reason: Reason
    package let expectedCount: Int
    package let loadedCount: Int
    package let missingCount: Int

    package var retryable: Bool {
        switch reason {
        case .emptyConfiguration, .invalidConfiguration, .workspaceUnavailable, .wrongRootKind: false
        default: true
        }
    }

    package init(
        reason: Reason,
        expectedCount: Int,
        loadedCount: Int,
        missingCount: Int
    ) {
        self.reason = reason
        self.expectedCount = expectedCount
        self.loadedCount = loadedCount
        self.missingCount = missingCount
    }
}

/// In-memory authority only; filesystem availability is deliberately observed off this actor.
package struct WorkspacePrimaryRootReadinessObservation: Equatable {
    package let primaryRoots: [WorkspaceRootRef]
    package let requestedRoots: [WorkspaceRootRef]
    package let missingPaths: [String]
    package let wrongKindPaths: [String]
    package let nonqueryablePaths: [String]
}
