import Combine
import Foundation
import OSLog

enum AgentContextFileBrowseUnavailableReason: Equatable {
    case sessionRootsUnavailable
    case catalogChanged
    case selectionTargetUnavailable
    case noRoots
}

enum AgentContextFileBrowsePhase: Equatable {
    case inactive
    case loadingRoots
    case ready
    case unavailable(AgentContextFileBrowseUnavailableReason)
}

enum AgentContextFileBrowseFocusTarget: Equatable, Hashable {
    case search
    case row(AgentContextFileBrowseNodeID)
}

struct AgentContextFileBrowseNotice: Equatable {
    let message: String
}

struct AgentContextFileBrowseRouteProof: Equatable {
    let identity: WorkspaceSelectionIdentity
    let lookupContext: WorkspaceLookupContext
}

enum AgentContextFileBrowseToggleDisabledReason: Equatable {
    case inFlight
    case unsupportedCodemap
    case codemapsDisabled
    case noSelectableFiles
    case obsoleteRequest
    case routeUnavailable
}

enum AgentContextFileBrowseToggleEligibility: Equatable {
    case enabled(WorkspacePreResolvedSelectionTargetState)
    case disabled(AgentContextFileBrowseToggleDisabledReason)

    var targetState: WorkspacePreResolvedSelectionTargetState? {
        guard case let .enabled(targetState) = self else { return nil }
        return targetState
    }
}

struct AgentContextFileBrowseFileStatus: Equatable {
    let heldMode: AgentContextFileBrowseHeldMode?
    let isAutomaticallyMapped: Bool
    let toggleEligibility: AgentContextFileBrowseToggleEligibility

    var isInFlight: Bool {
        toggleEligibility == .disabled(.inFlight)
    }

    var isCodemapBlocked: Bool {
        switch toggleEligibility {
        case .disabled(.unsupportedCodemap), .disabled(.codemapsDisabled): true
        case .enabled, .disabled: false
        }
    }
}

struct AgentContextFileBrowseContainerStatus: Equatable {
    let membership: AgentContextFileBrowseContainerMembership
    let totalFileCount: Int
    let selectableFileCount: Int
    let selectedFileCount: Int
    let unsupportedFileCount: Int
    let toggleEligibility: AgentContextFileBrowseToggleEligibility

    var isInFlight: Bool {
        toggleEligibility == .disabled(.inFlight)
    }

    var addableFileCount: Int {
        selectableFileCount - selectedFileCount
    }
}

struct AgentContextFileBrowseAccessibilityAnnouncement: Equatable {
    let id: UUID
    let message: String
}

enum AgentContextFileBrowseRow: Equatable, Identifiable {
    enum ID: Equatable, Hashable {
        case node(AgentContextFileBrowseNodeID)
        case loading(AgentContextFileBrowseNodeID)
        case emptyContainer(AgentContextFileBrowseNodeID)
    }

    case root(AgentContextFileBrowseRoot)
    case folder(AgentContextFileBrowseFolder, depth: Int)
    case file(AgentContextFileBrowseFile, depth: Int)
    case searchRootHeader(AgentContextFileBrowseSearchRootGroup)
    case searchDirectoryHeader(AgentContextFileBrowseSearchDirectoryGroup)
    case loading(parent: AgentContextFileBrowseNodeID, depth: Int)
    case emptyContainer(parent: AgentContextFileBrowseNodeID, depth: Int)

    var id: ID {
        switch self {
        case let .root(root): .node(.root(root.id))
        case let .folder(folder, _): .node(.folder(folder.id))
        case let .file(file, _): .node(.file(file.id))
        case let .searchRootHeader(group): .node(group.id)
        case let .searchDirectoryHeader(group): .node(group.id)
        case let .loading(parent, _): .loading(parent)
        case let .emptyContainer(parent, _): .emptyContainer(parent)
        }
    }

    var interactiveNodeID: AgentContextFileBrowseNodeID? {
        switch self {
        case let .root(root): .root(root.id)
        case let .folder(folder, _): .folder(folder.id)
        case let .file(file, _): .file(file.id)
        case .searchRootHeader, .searchDirectoryHeader, .loading, .emptyContainer: nil
        }
    }
}

@MainActor
final class AgentContextFileBrowseModel: ObservableObject {
    typealias MutationExecutor = @MainActor (
        _ paths: [String],
        _ targetState: WorkspacePreResolvedSelectionTargetState,
        _ identity: WorkspaceSelectionIdentity,
        _ lookupContext: WorkspaceLookupContext
    ) async -> WorkspaceSelectionCoordinator.TransactionResult?
    private struct Session {
        let generation: UInt64
        let identity: WorkspaceSelectionIdentity
        let lookupContext: WorkspaceLookupContext
    }

    /// Expanded container paths carried from the previous browse session on the same route, so
    /// leaving and re-entering browse mode returns the user to the tree they were working in.
    private struct RetainedExpansion {
        let identity: WorkspaceSelectionIdentity
        let lookupContext: WorkspaceLookupContext
        let containerPaths: Set<String>
    }

    private struct MutationRequest {
        let generation: UInt64
        let catalogGeneration: UInt64
        let identity: WorkspaceSelectionIdentity
        let lookupContext: WorkspaceLookupContext
        let files: [AgentContextFileBrowseFile]
        let targetState: WorkspacePreResolvedSelectionTargetState
    }

    private struct MutationWorker {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private struct ContainerFileContribution {
        let fileID: UUID
        let supportsCodemap: Bool
    }

    private struct ContainerAggregate {
        var totalFileCount = 0
        var selectableFileCount = 0
        var selectedFileCount = 0
        var unsupportedFileCount = 0
        var inFlightFileCount = 0
        var knownEstimateCount = 0
        var knownTokenTotal = 0
        var unavailableEstimateCount = 0
        var loadingEstimateCount = 0
    }

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "ContextFileBrowse")

    @Published private(set) var phase: AgentContextFileBrowsePhase = .inactive
    @Published private(set) var roots: [AgentContextFileBrowseRoot] = []
    @Published private(set) var rows: [AgentContextFileBrowseRow] = []
    @Published private(set) var visibleInteractiveRowOrder: [AgentContextFileBrowseNodeID] = []
    @Published private(set) var searchGroups: [AgentContextFileBrowseSearchRootGroup] = []
    @Published private(set) var expandedNodeIDs: Set<AgentContextFileBrowseNodeID> = []
    @Published private(set) var loadingChildNodeIDs: Set<AgentContextFileBrowseNodeID> = []
    @Published private(set) var inFlightPaths: Set<String> = []
    @Published private(set) var pendingMutationIdentities: Set<WorkspaceSelectionIdentity> = []
    @Published private(set) var focusTarget: AgentContextFileBrowseFocusTarget?
    @Published private(set) var notice: AgentContextFileBrowseNotice?
    @Published private(set) var accessibilityAnnouncement: AgentContextFileBrowseAccessibilityAnnouncement?
    @Published private(set) var query = ""
    @Published private(set) var rootScope: AgentContextFileBrowseRootScope = .allRoots
    @Published private(set) var addMode: AgentContextFileBrowseAddMode = .full
    @Published private(set) var codeMapsGloballyDisabled = false
    @Published private(set) var tokenReadinessRevision: UInt64 = 0

    private let service: AgentContextFileBrowseService
    private let estimator: AgentContextFileSizeEstimator
    private let mutationExecutor: MutationExecutor
    private let searchDebounceNanoseconds: UInt64
    private let noticeDurationNanoseconds: UInt64

    private var session: Session?
    private var mutationRouteProof: AgentContextFileBrowseRouteProof?
    private var sessionGeneration: UInt64 = 0
    private var sessionCatalogGeneration: UInt64?
    private var searchGeneration: UInt64 = 0
    private var authoritativeSelection = StoredSelection()
    private var authoritativeSelectionUpdateVersion: UInt64 = 0
    private var exportRows: [AgentContextExportRow] = []
    private var heldModesByPath: [String: AgentContextFileBrowseHeldMode] = [:]
    private var automaticCodemapPaths: Set<String> = []
    private var didLogSelectionOverlap = false
    private var acceptedRootGenerationByRootID: [UUID: UInt64] = [:]
    private var selectedAncestorDirectoryPaths: Set<String> = []
    private var retainedExpansion: RetainedExpansion?
    private var pendingExpansionRestorePaths: Set<String> = []
    private var enabledNodeIDs: Set<AgentContextFileBrowseNodeID> = []
    private var hierarchyByContainer: [AgentContextFileBrowseNodeID: AgentContextFileBrowseHierarchy] = [:]
    private var containerAggregates: [AgentContextFileBrowseNodeID: ContainerAggregate] = [:]
    private var containerIDsByFileID: [UUID: Set<AgentContextFileBrowseNodeID>] = [:]
    private var containerFileContributionByPath: [String: ContainerFileContribution] = [:]
    private var filesByID: [UUID: AgentContextFileBrowseFile] = [:]
    private var foldersByID: [UUID: AgentContextFileBrowseFolder] = [:]
    private var tokenEstimatesByFileID: [UUID: AgentContextFileBrowseTokenEstimate] = [:]
    private var estimateOwnerByFileID: [UUID: AgentContextFileBrowseNodeID] = [:]
    private var hierarchyTasks: [AgentContextFileBrowseNodeID: Task<Void, Never>] = [:]
    private var tokenTasks: [AgentContextFileBrowseNodeID: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var mutationWorker: MutationWorker?
    private var mutationQueue: [MutationRequest] = []
    private var pendingMutationCountByIdentity: [WorkspaceSelectionIdentity: Int] = [:]
    private var noticeDismissalTask: Task<Void, Never>?

    init(
        service: AgentContextFileBrowseService,
        estimator: AgentContextFileSizeEstimator,
        searchDebounceNanoseconds: UInt64 = 120_000_000,
        noticeDurationNanoseconds: UInt64 = 4_000_000_000,
        mutationExecutor: @escaping MutationExecutor
    ) {
        self.service = service
        self.estimator = estimator
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
        self.noticeDurationNanoseconds = noticeDurationNanoseconds
        self.mutationExecutor = mutationExecutor
    }

    var isActive: Bool {
        phase != .inactive
    }

    var capturedIdentity: WorkspaceSelectionIdentity? {
        session?.identity
    }

    func begin(
        target: AgentContextSelectionMutationTarget,
        lookupContext: WorkspaceLookupContext,
        exportRows: [AgentContextExportRow],
        codeMapsGloballyDisabled: Bool
    ) async {
        guard !Task.isCancelled else { return }
        end()
        pendingExpansionRestorePaths = if let retainedExpansion,
                                          retainedExpansion.identity == target.identity,
                                          retainedExpansion.lookupContext == lookupContext
        {
            retainedExpansion.containerPaths
        } else {
            []
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        session = Session(generation: generation, identity: target.identity, lookupContext: lookupContext)
        phase = .loadingRoots
        rootScope = .allRoots
        addMode = .full
        self.codeMapsGloballyDisabled = codeMapsGloballyDisabled
        authoritativeSelection = target.expectedSelection
        self.exportRows = exportRows
        rebuildSelectionProjection()

        let result = await service.roots(lookupContext: lookupContext)
        guard isCurrentSession(generation) else { return }
        switch result {
        case .unavailable:
            async let servicePrune: Void = service.pruneCaches(
                retainingRootIDs: [],
                lookupContext: lookupContext
            )
            async let estimatorPrune: Void = estimator.pruneCaches(retainingRootIDs: [])
            _ = await (servicePrune, estimatorPrune)
            guard isCurrentSession(generation) else { return }
            phase = .unavailable(.sessionRootsUnavailable)
        case let .available(snapshot):
            sessionCatalogGeneration = snapshot.catalogGeneration
            roots = snapshot.roots
            let retainedRootIDs = Set(roots.map(\.id))
            async let servicePrune: Void = service.pruneCaches(
                retainingRootIDs: retainedRootIDs,
                lookupContext: lookupContext
            )
            async let estimatorPrune: Void = estimator.pruneCaches(retainingRootIDs: retainedRootIDs)
            _ = await (servicePrune, estimatorPrune)
            guard isCurrentSession(generation) else { return }
            guard !roots.isEmpty else {
                phase = .unavailable(.noRoots)
                return
            }
            phase = .ready
            focusTarget = .search
            restorePendingExpansion(for: roots.map {
                (nodeID: AgentContextFileBrowseNodeID.root($0.id), path: $0.physicalPath)
            })
            rebuildRows()
        }
    }

    func end() {
        if let session {
            retainedExpansion = RetainedExpansion(
                identity: session.identity,
                lookupContext: session.lookupContext,
                containerPaths: Set(expandedNodeIDs.compactMap(containerPath(for:)))
            )
        }
        sessionGeneration &+= 1
        session = nil
        sessionCatalogGeneration = nil
        cancelBrowseWork()
        phase = .inactive
        roots = []
        rows = []
        visibleInteractiveRowOrder = []
        searchGroups = []
        expandedNodeIDs = []
        loadingChildNodeIDs = []
        inFlightPaths = []
        focusTarget = nil
        notice = nil
        accessibilityAnnouncement = nil
        query = ""
        rootScope = .allRoots
        addMode = .full
        codeMapsGloballyDisabled = false
        tokenReadinessRevision = 0
        authoritativeSelection = StoredSelection()
        exportRows = []
        heldModesByPath = [:]
        automaticCodemapPaths = []
        didLogSelectionOverlap = false
        hierarchyByContainer = [:]
        containerAggregates = [:]
        containerIDsByFileID = [:]
        containerFileContributionByPath = [:]
        filesByID = [:]
        foldersByID = [:]
        tokenEstimatesByFileID = [:]
        estimateOwnerByFileID = [:]
        enabledNodeIDs = []
        acceptedRootGenerationByRootID = [:]
        selectedAncestorDirectoryPaths = []
        pendingExpansionRestorePaths = []
    }

    func sessionMatches(identity: WorkspaceSelectionIdentity, lookupContext: WorkspaceLookupContext) -> Bool {
        session?.identity == identity && session?.lookupContext == lookupContext
    }

    func updateMutationRouteProof(_ proof: AgentContextFileBrowseRouteProof?) {
        mutationRouteProof = proof
    }

    func applySelectionChange(
        _ change: WorkspaceSelectionCoordinator.Change,
        exportRows: [AgentContextExportRow]
    ) {
        guard let session, change.tabID == session.identity.tabID else { return }
        authoritativeSelection = change.selection
        authoritativeSelectionUpdateVersion &+= 1
        self.exportRows = exportRows
        rebuildSelectionProjection()
    }

    func updateAuthoritativeSelection(_ selection: StoredSelection, exportRows: [AgentContextExportRow]) {
        guard session != nil else { return }
        authoritativeSelection = selection
        authoritativeSelectionUpdateVersion &+= 1
        self.exportRows = exportRows
        rebuildSelectionProjection()
    }

    func setQuery(_ value: String) {
        guard session != nil else { return }
        query = value
        scheduleSearch()
    }

    func setRootScope(_ scope: AgentContextFileBrowseRootScope) {
        guard session != nil, rootScope != scope else { return }
        rootScope = scope
        scheduleSearch()
    }

    func setAddMode(_ mode: AgentContextFileBrowseAddMode) {
        guard session != nil else { return }
        guard mode != .codemapOnly || !codeMapsGloballyDisabled else { return }
        addMode = mode
        rebuildContainerAggregates()
        rebuildRows()
    }

    func setCodeMapsGloballyDisabled(_ disabled: Bool) {
        guard session != nil else { return }
        codeMapsGloballyDisabled = disabled
        if disabled { addMode = .full }
        rebuildContainerAggregates()
        rebuildRows()
    }

    func heldMode(for file: AgentContextFileBrowseFile) -> AgentContextFileBrowseHeldMode? {
        fileStatus(for: file).heldMode
    }

    func isAutomaticallyMapped(_ file: AgentContextFileBrowseFile) -> Bool {
        fileStatus(for: file).isAutomaticallyMapped
    }

    func fileStatus(for file: AgentContextFileBrowseFile) -> AgentContextFileBrowseFileStatus {
        let path = file.standardizedFullPath
        let heldMode = heldModesByPath[path]
        let eligibility: AgentContextFileBrowseToggleEligibility = if !routeIsCurrent() {
            .disabled(.routeUnavailable)
        } else if !enabledNodeIDs.contains(.file(file.id)) {
            .disabled(.obsoleteRequest)
        } else if inFlightPaths.contains(path) {
            .disabled(.inFlight)
        } else if heldMode != nil {
            .enabled(.unselected)
        } else if addMode == .full {
            .enabled(.full)
        } else if codeMapsGloballyDisabled {
            .disabled(.codemapsDisabled)
        } else if !file.supportsCodemap {
            .disabled(.unsupportedCodemap)
        } else {
            .enabled(.codemapOnly)
        }
        return AgentContextFileBrowseFileStatus(
            heldMode: heldMode,
            isAutomaticallyMapped: automaticCodemapPaths.contains(path),
            toggleEligibility: eligibility
        )
    }

    func containerStatus(for nodeID: AgentContextFileBrowseNodeID) -> AgentContextFileBrowseContainerStatus? {
        guard let aggregate = containerAggregates[nodeID],
              let membership = membership(for: nodeID)
        else { return nil }
        let addableFileCount = aggregate.selectableFileCount - aggregate.selectedFileCount
        let eligibility: AgentContextFileBrowseToggleEligibility = if !routeIsCurrent() {
            .disabled(.routeUnavailable)
        } else if !enabledNodeIDs.contains(nodeID) {
            .disabled(.obsoleteRequest)
        } else if aggregate.inFlightFileCount > 0 {
            .disabled(.inFlight)
        } else if membership == .all, aggregate.totalFileCount > 0 {
            .enabled(.unselected)
        } else if addableFileCount > 0 {
            .enabled(addMode == .full ? .full : .codemapOnly)
        } else {
            .disabled(.noSelectableFiles)
        }
        return AgentContextFileBrowseContainerStatus(
            membership: membership,
            totalFileCount: aggregate.totalFileCount,
            selectableFileCount: aggregate.selectableFileCount,
            selectedFileCount: aggregate.selectedFileCount,
            unsupportedFileCount: aggregate.unsupportedFileCount,
            toggleEligibility: eligibility
        )
    }

    func membership(for nodeID: AgentContextFileBrowseNodeID) -> AgentContextFileBrowseContainerMembership? {
        guard let aggregate = containerAggregates[nodeID] else { return nil }
        guard aggregate.selectableFileCount > 0 else { return AgentContextFileBrowseContainerMembership.none }
        if aggregate.selectedFileCount == 0 { return AgentContextFileBrowseContainerMembership.none }
        if aggregate.selectedFileCount == aggregate.selectableFileCount { return .all }
        return .mixed
    }

    /// Checkbox state for a container row. A resolved container reports exact membership. An
    /// unresolved container still reports `.mixed` when the selection holds one of its
    /// descendants, so a collapsed folder shows that selected files came from inside it.
    func containerDisplayMembership(
        for nodeID: AgentContextFileBrowseNodeID
    ) -> AgentContextFileBrowseContainerMembership {
        if let membership = membership(for: nodeID) { return membership }
        guard let path = containerPath(for: nodeID) else {
            return AgentContextFileBrowseContainerMembership.none
        }
        return selectedAncestorDirectoryPaths.contains(path)
            ? .mixed
            : AgentContextFileBrowseContainerMembership.none
    }

    private func containerPath(for nodeID: AgentContextFileBrowseNodeID) -> String? {
        switch nodeID {
        case let .root(rootID):
            guard let root = roots.first(where: { $0.id == rootID }) else { return nil }
            return Self.normalizedPath(root.physicalPath)
        case let .folder(folderID):
            guard let folder = foldersByID[folderID] else { return nil }
            return Self.normalizedPath(folder.standardizedFullPath)
        case .file, .searchRootHeader, .searchDirectoryHeader:
            return nil
        }
    }

    private static func ancestorDirectoryPaths(of paths: some Collection<String>) -> Set<String> {
        var ancestors: Set<String> = []
        for path in paths {
            var current = (path as NSString).deletingLastPathComponent
            while current.count > 1, !ancestors.contains(current) {
                ancestors.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }
        return ancestors
    }

    func tokenEstimate(for nodeID: AgentContextFileBrowseNodeID) -> AgentContextFileBrowseTokenEstimate {
        switch nodeID {
        case let .file(fileID):
            return tokenEstimatesByFileID[fileID] ?? .notRequested
        case .root, .folder:
            guard let aggregate = containerAggregates[nodeID] else { return .notRequested }
            if aggregate.loadingEstimateCount > 0 { return .loading }
            if aggregate.knownEstimateCount + aggregate.unavailableEstimateCount < aggregate.totalFileCount {
                return .notRequested
            }
            if aggregate.unavailableEstimateCount > 0 { return .unavailable }
            return .known(aggregate.knownTokenTotal)
        case .searchRootHeader, .searchDirectoryHeader:
            return .notRequested
        }
    }

    func toggleExpansion(_ nodeID: AgentContextFileBrowseNodeID) {
        guard session != nil, Self.isContainer(nodeID) else { return }
        if expandedNodeIDs.remove(nodeID) != nil {
            rebuildRows()
            return
        }
        expandedNodeIDs.insert(nodeID)
        rebuildRows()
        requestHierarchy(for: nodeID)
    }

    /// Re-expands containers the previous session left open. Each path is consumed as it is
    /// applied, so a container the user collapses during this session stays collapsed.
    private func restorePendingExpansion(
        for containers: [(nodeID: AgentContextFileBrowseNodeID, path: String)]
    ) {
        guard !pendingExpansionRestorePaths.isEmpty else { return }
        for container in containers {
            guard pendingExpansionRestorePaths.remove(Self.normalizedPath(container.path)) != nil else { continue }
            guard expandedNodeIDs.insert(container.nodeID).inserted else { continue }
            requestHierarchy(for: container.nodeID)
        }
    }

    func rowBecameVisible(_ nodeID: AgentContextFileBrowseNodeID) {
        switch nodeID {
        case .root, .folder:
            break
        case let .file(fileID):
            guard let file = filesByID[fileID] else { return }
            requestFileEstimate(file)
        case .searchRootHeader, .searchDirectoryHeader:
            break
        }
    }

    func rowDisappeared(_ nodeID: AgentContextFileBrowseNodeID) {
        guard case .file = nodeID else { return }
        cancelEstimateRequest(owner: nodeID)
    }

    func toggleFile(_ file: AgentContextFileBrowseFile) -> Bool {
        guard let targetState = fileStatus(for: file).toggleEligibility.targetState else { return false }
        enqueueMutation(files: [file], targetState: targetState)
        return true
    }

    func toggleContainer(_ nodeID: AgentContextFileBrowseNodeID) -> Bool {
        guard let hierarchy = hierarchyByContainer[nodeID],
              let targetState = containerStatus(for: nodeID)?.toggleEligibility.targetState
        else { return false }
        let files = if targetState == .unselected {
            hierarchy.descendantFiles
        } else {
            selectableDescendants(from: hierarchy.descendantFiles).filter {
                heldModesByPath[$0.standardizedFullPath] == nil
            }
        }
        guard !files.isEmpty else { return false }
        enqueueMutation(files: files, targetState: targetState)
        return true
    }

    func focusNextRow() {
        moveFocus(offset: 1)
    }

    func focusPreviousRow() {
        moveFocus(offset: -1)
    }

    func focusSearch() {
        focusTarget = .search
    }

    func setFocusTarget(_ target: AgentContextFileBrowseFocusTarget) {
        guard session != nil else { return }
        focusTarget = target
    }

    func clearQueryOrEnd() {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setQuery("")
        } else {
            end()
        }
    }

    func dismissNotice() {
        noticeDismissalTask?.cancel()
        noticeDismissalTask = nil
        notice = nil
    }

    private func rebuildSelectionProjection() {
        guard let session else { return }
        let physical = session.lookupContext.physicalizeSelection(authoritativeSelection)
        let selected = Set(StoredSelectionPathNormalization.standardizedPaths(physical.selectedPaths))
        let sliced = Set(StoredSelectionPathNormalization.standardizedSlices(physical.slices).compactMap { path, ranges in
            ranges.isEmpty ? nil : path
        })
        let manual = Set(StoredSelectionPathNormalization.standardizedPaths(physical.manualCodemapPaths))
        if !didLogSelectionOverlap, !manual.intersection(selected.union(sliced)).isEmpty {
            didLogSelectionOverlap = true
            Self.logger.error("Context file browse found overlapping explicit selection representations")
        }

        var projection: [String: AgentContextFileBrowseHeldMode] = [:]
        projection.reserveCapacity(selected.count + sliced.count + manual.count)
        for path in manual {
            projection[path] = .codemap
        }
        for path in selected {
            projection[path] = .full
        }
        for path in sliced {
            projection[path] = .slice
        }
        let previousProjection = heldModesByPath
        heldModesByPath = projection
        updateSelectionAggregates(from: previousProjection, to: projection)
        selectedAncestorDirectoryPaths = Self.ancestorDirectoryPaths(of: projection.keys)

        automaticCodemapPaths = Set(exportRows.compactMap { row -> String? in
            guard row.kind == .codemap, let physicalPath = row.physicalPath else { return nil }
            let normalized = Self.normalizedPath(physicalPath)
            return manual.contains(normalized) ? nil : normalized
        })
        rebuildRows()
    }

    private func updateSelectionAggregates(
        from previous: [String: AgentContextFileBrowseHeldMode],
        to current: [String: AgentContextFileBrowseHeldMode]
    ) {
        let changedPaths = Set(previous.keys).symmetricDifference(Set(current.keys))
        for path in changedPaths {
            guard let contribution = containerFileContributionByPath[path] else { continue }
            for containerID in containerIDsByFileID[contribution.fileID] ?? [] {
                guard var aggregate = containerAggregates[containerID] else { continue }
                applySelectionContribution(
                    supportsCodemap: contribution.supportsCodemap,
                    isSelected: previous[path] != nil,
                    multiplier: -1,
                    to: &aggregate
                )
                applySelectionContribution(
                    supportsCodemap: contribution.supportsCodemap,
                    isSelected: current[path] != nil,
                    multiplier: 1,
                    to: &aggregate
                )
                containerAggregates[containerID] = aggregate
            }
        }
    }

    private func applySelectionContribution(
        supportsCodemap: Bool,
        isSelected: Bool,
        multiplier: Int,
        to aggregate: inout ContainerAggregate
    ) {
        let isSelectable = addMode == .full
            || isSelected
            || (supportsCodemap && !codeMapsGloballyDisabled)
        aggregate.selectableFileCount += isSelectable ? multiplier : 0
        aggregate.selectedFileCount += isSelected && isSelectable ? multiplier : 0
        aggregate.unsupportedFileCount += isSelectable ? 0 : multiplier
    }

    private func selectableDescendants(
        from files: [AgentContextFileBrowseFile]
    ) -> [AgentContextFileBrowseFile] {
        guard addMode == .codemapOnly else { return files }
        return files.filter {
            heldModesByPath[$0.standardizedFullPath] != nil
                || ($0.supportsCodemap && !codeMapsGloballyDisabled)
        }
    }

    private func rebuildContainerAggregates() {
        var aggregates: [AgentContextFileBrowseNodeID: ContainerAggregate] = [:]
        var containerIDs: [UUID: Set<AgentContextFileBrowseNodeID>] = [:]
        var contributionsByPath: [String: ContainerFileContribution] = [:]
        for (nodeID, hierarchy) in hierarchyByContainer {
            var aggregate = ContainerAggregate()
            for file in hierarchy.descendantFiles {
                containerIDs[file.id, default: []].insert(nodeID)
                contributionsByPath[file.standardizedFullPath] = ContainerFileContribution(
                    fileID: file.id,
                    supportsCodemap: file.supportsCodemap
                )
                accumulate(file: file, into: &aggregate)
            }
            aggregates[nodeID] = aggregate
        }
        containerAggregates = aggregates
        containerIDsByFileID = containerIDs
        containerFileContributionByPath = contributionsByPath
    }

    private func accumulate(file: AgentContextFileBrowseFile, into aggregate: inout ContainerAggregate) {
        let path = file.standardizedFullPath
        aggregate.totalFileCount += 1
        applySelectionContribution(
            supportsCodemap: file.supportsCodemap,
            isSelected: heldModesByPath[path] != nil,
            multiplier: 1,
            to: &aggregate
        )
        aggregate.inFlightFileCount += inFlightPaths.contains(path) ? 1 : 0
        Self.applyEstimate(tokenEstimatesByFileID[file.id], multiplier: 1, to: &aggregate)
    }

    private func setTokenEstimate(
        _ estimate: AgentContextFileBrowseTokenEstimate?,
        fileID: UUID
    ) {
        let previous = tokenEstimatesByFileID[fileID]
        guard previous != estimate else { return }
        tokenEstimatesByFileID[fileID] = estimate
        for containerID in containerIDsByFileID[fileID] ?? [] {
            guard var aggregate = containerAggregates[containerID] else { continue }
            Self.applyEstimate(previous, multiplier: -1, to: &aggregate)
            Self.applyEstimate(estimate, multiplier: 1, to: &aggregate)
            containerAggregates[containerID] = aggregate
        }
    }

    private static func applyEstimate(
        _ estimate: AgentContextFileBrowseTokenEstimate?,
        multiplier: Int,
        to aggregate: inout ContainerAggregate
    ) {
        switch estimate {
        case let .known(tokens):
            aggregate.knownEstimateCount += multiplier
            aggregate.knownTokenTotal += tokens * multiplier
        case .unavailable:
            aggregate.unavailableEstimateCount += multiplier
        case .loading:
            aggregate.loadingEstimateCount += multiplier
        case .notRequested, nil:
            break
        }
    }

    private func updateInFlightAggregates(
        for files: [AgentContextFileBrowseFile],
        multiplier: Int
    ) {
        for file in files {
            for containerID in containerIDsByFileID[file.id] ?? [] {
                guard var aggregate = containerAggregates[containerID] else { continue }
                aggregate.inFlightFileCount += multiplier
                containerAggregates[containerID] = aggregate
            }
        }
    }

    private func routeIsCurrent() -> Bool {
        guard let session else { return false }
        return mutationRouteProof == AgentContextFileBrowseRouteProof(
            identity: session.identity,
            lookupContext: session.lookupContext
        )
    }

    private func scheduleSearch() {
        searchGeneration &+= 1
        let requestGeneration = searchGeneration
        searchTask?.cancel()
        searchGroups = []
        rebuildRows()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session, !trimmedQuery.isEmpty else {
            searchGroups = []
            rebuildRows()
            return
        }
        let sessionGeneration = session.generation
        let scope = rootScope
        let lookupContext = session.lookupContext
        searchTask = Task { [weak self, service, searchDebounceNanoseconds] in
            do {
                if searchDebounceNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: searchDebounceNanoseconds)
                }
                let scopedResult = try await service.search(
                    query: trimmedQuery,
                    scope: scope,
                    lookupContext: lookupContext
                )
                try Task.checkCancellation()
                guard let self,
                      isCurrentSession(sessionGeneration),
                      searchGeneration == requestGeneration
                else { return }
                guard case let .available(result) = scopedResult else {
                    transitionToSessionRootsUnavailable()
                    return
                }
                guard result.catalogGeneration == sessionCatalogGeneration else {
                    transitionToCatalogChanged()
                    return
                }
                searchGroups = acceptingSearchGroups(result.groups)
                let matchedFiles = searchGroups.flatMap { group in
                    group.rootMatches.map(\.file) + group.directories.flatMap { $0.matches.map(\.file) }
                }
                indexSearchFiles(matchedFiles)
                rebuildRows()
            } catch is CancellationError {
                return
            } catch {
                guard let self, isCurrentSession(sessionGeneration) else { return }
                Self.logger.error("Context file browse search failed: \(error.localizedDescription, privacy: .public)")
                searchGroups = []
                rebuildRows()
            }
        }
    }

    private func requestHierarchy(for nodeID: AgentContextFileBrowseNodeID) {
        guard hierarchyByContainer[nodeID] == nil,
              hierarchyTasks[nodeID] == nil,
              let session,
              let location = containerLocation(nodeID)
        else { return }
        loadingChildNodeIDs.insert(nodeID)
        rebuildRows()
        let generation = session.generation
        hierarchyTasks[nodeID] = Task { [weak self, service] in
            do {
                let scopedResult = try await service.hierarchy(
                    rootID: location.rootID,
                    folderID: location.folderID,
                    lookupContext: session.lookupContext
                )
                try Task.checkCancellation()
                guard let self, isCurrentSession(generation) else { return }
                hierarchyTasks[nodeID] = nil
                loadingChildNodeIDs.remove(nodeID)
                let hierarchy: AgentContextFileBrowseHierarchy
                switch scopedResult {
                case let .available(result):
                    hierarchy = result
                case let .missing(catalogGeneration):
                    guard catalogGeneration == sessionCatalogGeneration else {
                        transitionToCatalogChanged()
                        return
                    }
                    expandedNodeIDs.remove(nodeID)
                    showNotice("This folder is no longer available")
                    rebuildRows()
                    return
                case .sessionRootsUnavailable:
                    transitionToSessionRootsUnavailable()
                    return
                }
                guard hierarchy.catalogGeneration == sessionCatalogGeneration else {
                    transitionToCatalogChanged()
                    return
                }
                let wasExpanded = expandedNodeIDs.contains(nodeID)
                guard acceptAppliedRootGeneration(
                    rootID: location.rootID,
                    generation: hierarchy.rootGeneration
                ) else {
                    rebuildRows()
                    return
                }
                if wasExpanded { expandedNodeIDs.insert(nodeID) }
                hierarchyByContainer[nodeID] = hierarchy
                indexHierarchy(hierarchy)
                rebuildContainerAggregates()
                restorePendingExpansion(for: hierarchy.folders.map {
                    (nodeID: AgentContextFileBrowseNodeID.folder($0.id), path: $0.standardizedFullPath)
                })
                rebuildRows()
            } catch is CancellationError {
                return
            } catch {
                guard let self, isCurrentSession(generation) else { return }
                hierarchyTasks[nodeID] = nil
                loadingChildNodeIDs.remove(nodeID)
                showNotice("This folder could not be loaded")
                rebuildRows()
            }
        }
    }

    private func transitionToSessionRootsUnavailable() {
        phase = .unavailable(.sessionRootsUnavailable)
        searchGroups = []
        rebuildRows()
    }

    private func transitionToCatalogChanged() {
        phase = .unavailable(.catalogChanged)
        searchGroups = []
        rebuildRows()
    }

    private func requestFileEstimate(_ file: AgentContextFileBrowseFile) {
        let nodeID = AgentContextFileBrowseNodeID.file(file.id)
        guard let session,
              tokenTasks[nodeID] == nil,
              let request = claimEstimateRequests(files: [file], owner: nodeID).first
        else { return }
        let generation = session.generation
        tokenTasks[nodeID] = Task { [weak self, estimator] in
            let results = await estimator.estimates(for: [request])
            guard let self, !Task.isCancelled, isCurrentSession(generation) else { return }
            applyEstimateResults(results, owner: nodeID)
        }
    }

    private func claimEstimateRequests(
        files: [AgentContextFileBrowseFile],
        owner: AgentContextFileBrowseNodeID
    ) -> [AgentContextFileSizeEstimateRequest] {
        let pending = files.filter {
            tokenEstimatesByFileID[$0.id] == nil && estimateOwnerByFileID[$0.id] == nil
        }
        guard !pending.isEmpty else { return [] }
        for file in pending {
            estimateOwnerByFileID[file.id] = owner
            setTokenEstimate(.loading, fileID: file.id)
        }
        tokenReadinessRevision &+= 1
        return pending.map {
            AgentContextFileSizeEstimateRequest(file: $0, rootGeneration: $0.rootGeneration)
        }
    }

    private func applyEstimateResults(
        _ results: [AgentContextFileSizeEstimateResult],
        owner: AgentContextFileBrowseNodeID
    ) {
        tokenTasks[owner] = nil
        var changed = false
        for result in results where estimateOwnerByFileID[result.fileID] == owner {
            estimateOwnerByFileID[result.fileID] = nil
            if filesByID[result.fileID]?.rootGeneration == result.rootGeneration,
               acceptedRootGenerationByRootID[result.rootID] == result.rootGeneration,
               result.estimate != .notRequested
            {
                setTokenEstimate(result.estimate, fileID: result.fileID)
            } else {
                setTokenEstimate(nil, fileID: result.fileID)
            }
            changed = true
        }
        if changed { tokenReadinessRevision &+= 1 }
    }

    private func cancelEstimateRequest(owner: AgentContextFileBrowseNodeID) {
        tokenTasks[owner]?.cancel()
        tokenTasks[owner] = nil
        let ownedFileIDs = estimateOwnerByFileID.compactMap { fileID, currentOwner in
            currentOwner == owner ? fileID : nil
        }
        guard !ownedFileIDs.isEmpty else { return }
        for fileID in ownedFileIDs {
            estimateOwnerByFileID[fileID] = nil
            if tokenEstimatesByFileID[fileID] == .loading {
                setTokenEstimate(nil, fileID: fileID)
            }
        }
        tokenReadinessRevision &+= 1
    }

    private func enqueueMutation(
        files: [AgentContextFileBrowseFile],
        targetState: WorkspacePreResolvedSelectionTargetState
    ) {
        guard let session, let sessionCatalogGeneration else { return }
        let paths = Set(files.map(\.standardizedFullPath))
        guard inFlightPaths.isDisjoint(with: paths) else { return }
        inFlightPaths.formUnion(paths)
        updateInFlightAggregates(for: files, multiplier: 1)
        mutationQueue.append(MutationRequest(
            generation: session.generation,
            catalogGeneration: sessionCatalogGeneration,
            identity: session.identity,
            lookupContext: session.lookupContext,
            files: files,
            targetState: targetState
        ))
        pendingMutationCountByIdentity[session.identity, default: 0] += 1
        pendingMutationIdentities.insert(session.identity)
        startMutationWorkerIfNeeded()
    }

    private func startMutationWorkerIfNeeded() {
        guard mutationWorker == nil, let generation = mutationQueue.first?.generation else { return }
        let workerID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await drainMutationQueue(workerID: workerID, generation: generation)
        }
        mutationWorker = MutationWorker(id: workerID, generation: generation, task: task)
    }

    private func drainMutationQueue(workerID: UUID, generation: UInt64) async {
        while !mutationQueue.isEmpty {
            guard mutationWorker?.id == workerID,
                  mutationWorker?.generation == generation,
                  mutationQueue.first?.generation == generation,
                  !Task.isCancelled
            else { break }
            let request = mutationQueue.removeFirst()
            defer { finishPendingMutation(request) }
            do {
                let scopedResult = try await service.revalidate(
                    files: request.files,
                    lookupContext: request.lookupContext
                )
                try Task.checkCancellation()
                guard case let .available(revalidated) = scopedResult else {
                    clearInFlight(request.files, generation: generation)
                    if isCurrentSession(generation) {
                        transitionToSessionRootsUnavailable()
                    }
                    break
                }
                guard revalidated.catalogGeneration == request.catalogGeneration else {
                    clearInFlight(request.files, generation: generation)
                    if isCurrentSession(generation) {
                        transitionToCatalogChanged()
                    }
                    break
                }
                let acceptedFiles = if isCurrentSession(generation) {
                    revalidated.files.filter {
                        acceptAppliedRootGeneration(rootID: $0.rootID, generation: $0.rootGeneration)
                    }
                } else {
                    revalidated.files
                }
                let rejectedCount = revalidated.rejectedCount + revalidated.files.count - acceptedFiles.count
                if rejectedCount > 0, isCurrentSession(generation) {
                    showNotice(Self.rejectedFileNotice(count: rejectedCount))
                }
                guard !acceptedFiles.isEmpty else {
                    clearInFlight(request.files, generation: generation)
                    continue
                }
                let paths = acceptedFiles.map(\.standardizedFullPath)
                // This task survives session exit so an accepted coordinator transaction can finish
                let selectionUpdateVersion = authoritativeSelectionUpdateVersion
                let transactionTask = Task { @MainActor [mutationExecutor] in
                    await mutationExecutor(
                        paths,
                        request.targetState,
                        request.identity,
                        request.lookupContext
                    )
                }
                let transaction = await transactionTask.value
                if let transaction {
                    if isCurrentSession(generation),
                       authoritativeSelectionUpdateVersion == selectionUpdateVersion
                    {
                        authoritativeSelection = transaction.after
                        rebuildSelectionProjection()
                    }
                } else if isCurrentSession(generation) {
                    showNotice("Selection is no longer available")
                    phase = .unavailable(.selectionTargetUnavailable)
                }
            } catch is CancellationError {
                clearInFlight(request.files, generation: generation)
                break
            } catch {
                if isCurrentSession(generation) {
                    Self.logger.error("Context file browse mutation failed: \(error.localizedDescription, privacy: .public)")
                    showNotice("Selection could not be updated")
                }
            }
            clearInFlight(request.files, generation: generation)
        }
        finishMutationWorker(workerID: workerID, generation: generation)
    }

    private func finishMutationWorker(workerID: UUID, generation: UInt64) {
        guard mutationWorker?.id == workerID, mutationWorker?.generation == generation else { return }
        mutationWorker = nil
        if !mutationQueue.isEmpty { startMutationWorkerIfNeeded() }
    }

    private func finishPendingMutation(_ request: MutationRequest) {
        let remaining = (pendingMutationCountByIdentity[request.identity] ?? 1) - 1
        if remaining > 0 {
            pendingMutationCountByIdentity[request.identity] = remaining
        } else {
            pendingMutationCountByIdentity[request.identity] = nil
            pendingMutationIdentities.remove(request.identity)
        }
    }

    private func clearInFlight(_ files: [AgentContextFileBrowseFile], generation: UInt64) {
        guard isCurrentSession(generation) else { return }
        updateInFlightAggregates(for: files, multiplier: -1)
        for file in files {
            inFlightPaths.remove(file.standardizedFullPath)
        }
    }

    private func showNotice(_ message: String) {
        noticeDismissalTask?.cancel()
        notice = AgentContextFileBrowseNotice(message: message)
        accessibilityAnnouncement = AgentContextFileBrowseAccessibilityAnnouncement(id: UUID(), message: message)
        guard noticeDurationNanoseconds > 0 else { return }
        let generation = session?.generation
        noticeDismissalTask = Task { [weak self, noticeDurationNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: noticeDurationNanoseconds)
                guard let self, session?.generation == generation else { return }
                notice = nil
            } catch {
                return
            }
        }
    }

    private func rebuildRows() {
        guard phase == .ready else {
            rows = []
            visibleInteractiveRowOrder = []
            enabledNodeIDs = []
            reconcileFocus()
            return
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            rows = searchGroups.flatMap { group in
                var groupRows: [AgentContextFileBrowseRow] = [.searchRootHeader(group)]
                groupRows.append(contentsOf: group.rootMatches.map { .file($0.file, depth: 0) })
                for directory in group.directories {
                    groupRows.append(.searchDirectoryHeader(directory))
                    groupRows.append(contentsOf: directory.matches.map { .file($0.file, depth: 0) })
                }
                return groupRows
            }
        } else {
            let scopedRoots = switch rootScope {
            case .allRoots: roots
            case let .root(rootID): roots.filter { $0.id == rootID }
            }
            rows = scopedRoots.flatMap { root -> [AgentContextFileBrowseRow] in
                let nodeID = AgentContextFileBrowseNodeID.root(root.id)
                var rootRows: [AgentContextFileBrowseRow] = [.root(root)]
                if expandedNodeIDs.contains(nodeID) {
                    appendChildren(of: nodeID, depth: 1, to: &rootRows)
                }
                return rootRows
            }
        }
        visibleInteractiveRowOrder = rows.compactMap(\.interactiveNodeID)
        enabledNodeIDs = Set(visibleInteractiveRowOrder)
        reconcileFocus()
    }

    private func appendChildren(
        of nodeID: AgentContextFileBrowseNodeID,
        depth: Int,
        to rows: inout [AgentContextFileBrowseRow]
    ) {
        guard let children = hierarchyByContainer[nodeID] else {
            if loadingChildNodeIDs.contains(nodeID) {
                rows.append(.loading(parent: nodeID, depth: depth))
            }
            return
        }
        if children.folders.isEmpty, children.files.isEmpty {
            rows.append(.emptyContainer(parent: nodeID, depth: depth))
            return
        }
        for folder in children.folders {
            let folderNodeID = AgentContextFileBrowseNodeID.folder(folder.id)
            rows.append(.folder(folder, depth: depth))
            if expandedNodeIDs.contains(folderNodeID) {
                appendChildren(of: folderNodeID, depth: depth + 1, to: &rows)
            }
        }
        rows.append(contentsOf: children.files.map { .file($0, depth: depth) })
    }

    private func reconcileFocus() {
        guard case let .row(nodeID) = focusTarget else { return }
        if !visibleInteractiveRowOrder.contains(nodeID) {
            focusTarget = visibleInteractiveRowOrder.first.map(AgentContextFileBrowseFocusTarget.row) ?? .search
        }
    }

    private func moveFocus(offset: Int) {
        guard !visibleInteractiveRowOrder.isEmpty else {
            focusTarget = .search
            return
        }
        let nextIndex: Int
        switch focusTarget {
        case let .row(nodeID):
            let current = visibleInteractiveRowOrder.firstIndex(of: nodeID) ?? 0
            nextIndex = min(max(current + offset, 0), visibleInteractiveRowOrder.count - 1)
        case .search, nil:
            nextIndex = offset < 0 ? visibleInteractiveRowOrder.count - 1 : 0
        }
        focusTarget = .row(visibleInteractiveRowOrder[nextIndex])
    }

    private func acceptingSearchGroups(
        _ groups: [AgentContextFileBrowseSearchRootGroup]
    ) -> [AgentContextFileBrowseSearchRootGroup] {
        for group in groups {
            let files = group.rootMatches.map(\.file) + group.directories.flatMap { $0.matches.map(\.file) }
            if let generation = files.map(\.rootGeneration).max() {
                _ = acceptAppliedRootGeneration(rootID: group.root.id, generation: generation)
            }
        }
        return groups.filter { group in
            let files = group.rootMatches.map(\.file) + group.directories.flatMap { $0.matches.map(\.file) }
            guard let accepted = acceptedRootGenerationByRootID[group.root.id] else { return false }
            return files.allSatisfy { $0.rootGeneration == accepted }
        }
    }

    private func acceptAppliedRootGeneration(rootID: UUID, generation: UInt64) -> Bool {
        if let accepted = acceptedRootGenerationByRootID[rootID] {
            guard generation >= accepted else { return false }
            guard generation > accepted else { return true }
            invalidateRootDerivedState(rootID: rootID)
        }
        acceptedRootGenerationByRootID[rootID] = generation
        return true
    }

    private func invalidateRootDerivedState(rootID: UUID) {
        let folderNodeIDs = Set(foldersByID.values.lazy.filter { $0.rootID == rootID }.map {
            AgentContextFileBrowseNodeID.folder($0.id)
        })
        let fileIDs = Set(filesByID.values.lazy.filter { $0.rootID == rootID }.map(\.id))
        let fileNodeIDs = Set(fileIDs.map(AgentContextFileBrowseNodeID.file))
        let containerNodeIDs = folderNodeIDs.union([.root(rootID)])
        let derivedNodeIDs = containerNodeIDs.union(fileNodeIDs)

        for nodeID in derivedNodeIDs {
            hierarchyTasks[nodeID]?.cancel()
            hierarchyTasks[nodeID] = nil
            cancelEstimateRequest(owner: nodeID)
        }
        for nodeID in containerNodeIDs {
            hierarchyByContainer[nodeID] = nil
            loadingChildNodeIDs.remove(nodeID)
        }
        expandedNodeIDs.subtract(containerNodeIDs)
        foldersByID = foldersByID.filter { $0.value.rootID != rootID }
        filesByID = filesByID.filter { $0.value.rootID != rootID }
        for fileID in fileIDs {
            tokenEstimatesByFileID[fileID] = nil
            estimateOwnerByFileID[fileID] = nil
        }
        rebuildContainerAggregates()
        searchGroups.removeAll { $0.root.id == rootID }
        enabledNodeIDs.subtract(derivedNodeIDs)
        if phase == .ready { rebuildRows() }
    }

    private func indexHierarchy(_ hierarchy: AgentContextFileBrowseHierarchy) {
        for folder in hierarchy.folders {
            foldersByID[folder.id] = folder
        }
        indexSearchFiles(hierarchy.files)
    }

    private func indexSearchFiles(_ files: [AgentContextFileBrowseFile]) {
        for file in files {
            filesByID[file.id] = file
        }
    }

    private func containerLocation(
        _ nodeID: AgentContextFileBrowseNodeID
    ) -> (rootID: UUID, folderID: UUID?)? {
        switch nodeID {
        case let .root(rootID):
            return (rootID, nil)
        case let .folder(folderID):
            guard let folder = foldersByID[folderID] else { return nil }
            return (folder.rootID, folderID)
        case .file, .searchRootHeader, .searchDirectoryHeader:
            return nil
        }
    }

    private func cancelBrowseWork() {
        searchTask?.cancel()
        searchTask = nil
        noticeDismissalTask?.cancel()
        noticeDismissalTask = nil
        for task in hierarchyTasks.values {
            task.cancel()
        }
        for task in tokenTasks.values {
            task.cancel()
        }
        hierarchyTasks = [:]
        tokenTasks = [:]
    }

    private func isCurrentSession(_ generation: UInt64) -> Bool {
        session?.generation == generation
    }

    private static func isContainer(_ nodeID: AgentContextFileBrowseNodeID) -> Bool {
        switch nodeID {
        case .root, .folder: true
        case .file, .searchRootHeader, .searchDirectoryHeader: false
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        StoredSelectionPathNormalization.standardizedPaths([path])[0]
    }

    private static func rejectedFileNotice(count: Int) -> String {
        count == 1 ? "1 file is no longer available" : "\(count) files are no longer available"
    }
}
