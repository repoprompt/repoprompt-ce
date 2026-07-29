import Combine
import Foundation

struct AgentWorkspaceCodemapPresentation: Equatable {
    enum State: Equatable {
        case notInitialized
        case indexing
        case ready
        case updating
        case reconciling
        case paused
        case unavailable
        case revoked
    }

    enum Tone: Equatable {
        case accent
        case success
        case warning
        case secondary
    }

    let state: State
    let isCatalogSealed: Bool
    let classifiedCount: UInt64
    let supportedCount: UInt64?
    let pendingCount: UInt64
    let updatesPending: Bool
    let graphRevision: UInt64?

    static let pending = Self(
        state: .notInitialized,
        isCatalogSealed: false,
        classifiedCount: 0,
        supportedCount: nil,
        pendingCount: 0,
        updatesPending: false,
        graphRevision: nil
    )

    var tone: Tone {
        switch state {
        case .notInitialized, .indexing, .updating: .accent
        case .reconciling: .warning
        case .ready: .success
        case .paused, .unavailable, .revoked: .secondary
        }
    }

    var isPaused: Bool {
        state == .paused
    }

    var canToggle: Bool {
        state != .unavailable && state != .revoked
    }

    var isActivelyMapping: Bool {
        switch state {
        case .notInitialized, .indexing, .updating, .reconciling: true
        case .ready, .paused, .unavailable, .revoked: false
        }
    }

    var showsProgress: Bool {
        switch state {
        case .notInitialized, .indexing, .updating, .reconciling: true
        case .ready, .paused, .unavailable, .revoked: false
        }
    }

    var progressFraction: Double? {
        if state == .ready, supportedCount == 0 { return 1 }
        guard isCatalogSealed, let supportedCount, supportedCount > 0 else { return nil }
        let fraction = min(1, Double(min(classifiedCount, supportedCount)) / Double(supportedCount))
        return state == .ready ? fraction : min(0.99, fraction)
    }

    var percentageText: String? {
        progressFraction.map { progress in
            if state != .ready, progress > 0, progress < 0.01 { return "<1%" }
            let percentage = Int((progress * 100).rounded(.down))
            return "\(state == .ready ? 100 : min(99, percentage))%"
        }
    }

    var statusText: String {
        let countText = classifiedCount > 0
            ? "\(classifiedCount) \(classifiedCount == 1 ? "file" : "files")"
            : nil
        return switch state {
        case .notInitialized: "Preparing…"
        case .indexing:
            percentageText.map { "Indexing \($0)" }
                ?? countText.map { "Indexing \($0)…" }
                ?? "Indexing — discovering files…"
        case .ready: "Mapped"
        case .updating:
            percentageText.map { "Updating \($0)" }
                ?? countText.map { "Updating \($0)…" }
                ?? "Updating — discovering files…"
        case .reconciling: "Reconciling…"
        case .paused: "Paused"
        case .unavailable: "Unavailable"
        case .revoked: "Revoked"
        }
    }

    var tooltip: String {
        switch state {
        case .notInitialized:
            "Code Map indexing is preparing."
        case .indexing:
            if let supportedCount {
                "Code Map graph coverage: \(classifiedCount) of \(supportedCount) files indexed (\(percentageText ?? "0%"))."
            } else if classifiedCount > 0 {
                "Code Map indexed \(classifiedCount) files while catalog discovery continues."
            } else {
                "Code Map indexing is in progress."
            }
        case .ready:
            "Code Map graph is ready with \(classifiedCount) indexed files."
        case .updating:
            "Code Map graph is usable and applying pending updates."
        case .reconciling:
            "Code Map graph is usable while watcher changes are reconciled."
        case .paused:
            "Paused for this loaded root. Resume to allow Code Map indexing."
        case .unavailable:
            "Code Maps are unavailable for this root."
        case .revoked:
            "Code Map graph authority was revoked and must be re-established."
        }
    }

    static func make(_ snapshot: WorkspaceCodemapRootStatusSnapshot?) -> Self {
        guard let snapshot else { return .pending }
        let state: State = if snapshot.isGenerationSuspended {
            .paused
        } else {
            switch snapshot.availability {
            case .notInitialized: .notInitialized
            case .indexing: .indexing
            case .ready: .ready
            case .updating: .updating
            case .reconciling: .reconciling
            case .unavailable: .unavailable
            case .revoked: .revoked
            }
        }
        let coverage = snapshot.coverage
        let isCatalogSealed = coverage?.isCatalogSealed == true
        let stableSupportedCount = isCatalogSealed ? coverage?.supportedCount : nil
        return Self(
            state: state,
            isCatalogSealed: isCatalogSealed,
            classifiedCount: coverage?.classifiedCount ?? 0,
            supportedCount: stableSupportedCount,
            pendingCount: coverage?.pendingCount ?? 0,
            updatesPending: snapshot.updatesPending,
            graphRevision: snapshot.graphRevision
        )
    }
}

struct AgentWorkspaceCodemapSummary: Equatable {
    enum State: Equatable {
        case indexing
        case reconciling
        case ready
        case paused
        case mixed
        case unavailable
    }

    let state: State
    let progressFraction: Double?
    let classifiedCount: UInt64?
    let supportedCount: UInt64?
    let readyRootCount: Int
    let reconcilingRootCount: Int
    let pausedRootCount: Int
    let preSealHeaderText: String

    var progressPercentage: Int? {
        guard state == .indexing || state == .reconciling, let progressFraction else { return nil }
        return min(99, max(0, Int((progressFraction * 100).rounded(.down))))
    }

    var label: String {
        switch state {
        case .indexing, .reconciling, .ready, .unavailable: "Code Map"
        case .paused: "Paused"
        case .mixed: "Partial"
        }
    }

    var showsIndeterminateProgress: Bool {
        (state == .indexing || state == .reconciling) && progressFraction == nil
    }

    var preSealProgressText: String {
        let progress = classifiedCount.flatMap { count -> String? in
            guard count > 0 else { return nil }
            return "\(count) \(count == 1 ? "file" : "files") indexed so far while repository catalogs are discovered."
        } ?? "Discovering repository catalogs…"
        guard pausedRootCount > 0 else { return progress }
        return "\(progress) \(pausedRootCount) \(pausedRootCount == 1 ? "root" : "roots") paused."
    }

    var detailText: String {
        switch state {
        case .indexing:
            let primary = progressPercentage.map { "Indexing \($0)%" } ?? preSealHeaderText
            var details = [primary]
            if reconcilingRootCount > 0 { details.append("\(reconcilingRootCount) reconciling") }
            if pausedRootCount > 0 { details.append("\(pausedRootCount) paused") }
            return details.joined(separator: " • ")
        case .reconciling:
            let primary = progressPercentage.map { "Reconciling watcher changes • \($0)%" }
                ?? preSealHeaderText
            return pausedRootCount > 0 ? "\(primary) • \(pausedRootCount) paused" : primary
        case .ready:
            return "All available roots mapped"
        case .paused:
            return "Indexing paused"
        case .mixed:
            return "\(readyRootCount) mapped • \(pausedRootCount) paused"
        case .unavailable:
            return "Code Maps unavailable"
        }
    }

    var tooltip: String {
        if showsIndeterminateProgress {
            return "\(detailText) \(preSealProgressText) Click for graph coverage and per-root controls."
        }
        return "\(detailText). Click for graph coverage and per-root controls."
    }

    var accessibilityValue: String {
        if let classifiedCount, let supportedCount, let progressPercentage {
            return "\(classifiedCount) of \(supportedCount) files indexed, \(progressPercentage) percent"
        }
        return showsIndeterminateProgress ? "\(detailText) \(preSealProgressText)" : detailText
    }

    static func make(_ presentations: [AgentWorkspaceCodemapPresentation]) -> Self {
        let availableRoots = presentations.filter(\.canToggle)
        let activelyMappingRoots = availableRoots.filter {
            switch $0.state {
            case .notInitialized, .indexing, .updating: true
            case .reconciling, .ready, .paused, .unavailable, .revoked: false
            }
        }
        let reconcilingRoots = availableRoots.filter { $0.state == .reconciling }
        let pausedRoots = availableRoots.filter(\.isPaused)
        let readyRoots = availableRoots.filter { $0.state == .ready }
        let activeNonPausedRoots = availableRoots.filter { !$0.isPaused }
        let classified = checkedSum(activeNonPausedRoots.map(\.classifiedCount))
        let totalsAreKnown = !activeNonPausedRoots.isEmpty && activeNonPausedRoots.allSatisfy {
            $0.isCatalogSealed && $0.supportedCount != nil
        }
        let supported = totalsAreKnown
            ? checkedSum(activeNonPausedRoots.compactMap(\.supportedCount))
            : nil
        let rawProgress = classified.flatMap { classified in
            supported.flatMap { supported -> Double? in
                guard supported > 0 else { return activelyMappingRoots.isEmpty ? 1 : nil }
                return min(1, Double(min(classified, supported)) / Double(supported))
            }
        }
        let state: State = if !activelyMappingRoots.isEmpty {
            .indexing
        } else if !reconcilingRoots.isEmpty {
            .reconciling
        } else if availableRoots.isEmpty {
            .unavailable
        } else if pausedRoots.count == availableRoots.count {
            .paused
        } else if readyRoots.count == availableRoots.count {
            .ready
        } else {
            .mixed
        }
        let progress: Double? = switch state {
        case .indexing, .reconciling:
            rawProgress.map { min(0.99, $0) }
        case .ready:
            1
        case .paused, .mixed, .unavailable:
            nil
        }
        let activeRootsAreUpdating = !activelyMappingRoots.isEmpty && activelyMappingRoots.allSatisfy {
            $0.state == .updating
        }
        let preSealHeaderText: String = switch state {
        case .indexing:
            activeRootsAreUpdating ? "Updating — discovering files…" : "Indexing — discovering files…"
        case .reconciling:
            "Reconciling — discovering files…"
        case .ready, .paused, .mixed, .unavailable:
            "Discovering files…"
        }
        return Self(
            state: state,
            progressFraction: progress,
            classifiedCount: classified,
            supportedCount: supported,
            readyRootCount: readyRoots.count,
            reconcilingRootCount: reconcilingRoots.count,
            pausedRootCount: pausedRoots.count,
            preSealHeaderText: preSealHeaderText
        )
    }

    private static func checkedSum(_ values: [UInt64]) -> UInt64? {
        values.reduce(UInt64?.some(0)) { partial, value in
            guard let partial else { return nil }
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? nil : sum
        }
    }
}

struct AgentWorkspaceRootRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let fullPath: String
    let standardizedFullPath: String
    let isPrimary: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let gitContext: GitWorktreeContextSummary?
    let worktree: AgentWorktreeIndicator?
    let codemap: AgentWorkspaceCodemapPresentation

    init(
        id: UUID,
        name: String,
        fullPath: String,
        standardizedFullPath: String? = nil,
        isPrimary: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool,
        gitContext: GitWorktreeContextSummary? = nil,
        worktree: AgentWorktreeIndicator? = nil,
        codemap: AgentWorkspaceCodemapPresentation = .pending
    ) {
        self.id = id
        self.name = name
        self.fullPath = fullPath
        self.standardizedFullPath = standardizedFullPath ?? StandardizedPath.absolute(fullPath)
        self.isPrimary = isPrimary
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.gitContext = gitContext
        self.worktree = worktree
        self.codemap = codemap
    }

    func withWorktree(_ worktree: AgentWorktreeIndicator?) -> AgentWorkspaceRootRow {
        AgentWorkspaceRootRow(
            id: id,
            name: name,
            fullPath: fullPath,
            standardizedFullPath: standardizedFullPath,
            isPrimary: isPrimary,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            gitContext: gitContext,
            worktree: worktree,
            codemap: codemap
        )
    }
}

@MainActor
final class AgentWorkspaceRootsSidebarStore: ObservableObject {
    @Published private(set) var rootRows: [AgentWorkspaceRootRow] = []
    @Published private(set) var workspaceLabel = "No Workspace"
    @Published private(set) var isExitDisabled = true
    @Published private(set) var codemapActionRootIDs: Set<UUID> = []

    private let rootProjections: @MainActor () -> [WorkspaceRootShellProjection]
    private let rootChanges: AnyPublisher<Void, Never>
    private let gitContextLookup: @MainActor (String) -> GitWorktreeContextSummary?
    private let gitContextChanges: AnyPublisher<Void, Never>
    private let codemapStatusLookup: @MainActor (UUID) -> WorkspaceCodemapRootStatusSnapshot?
    private let codemapStatusChanges: AnyPublisher<Void, Never>
    private let setCodemapSuspended: @MainActor (UUID, Bool) async -> Void
    private let workspaceManager: WorkspaceManagerViewModel
    let windowID: Int

    private var cancellables: Set<AnyCancellable> = []
    private var rootRowsResnapshotTask: Task<Void, Never>?
    private var workspaceMetadataResnapshotTask: Task<Void, Never>?

    var workspaceManagerForPicker: WorkspaceManagerViewModel {
        workspaceManager
    }

    init(
        rootProjections: @escaping @MainActor () -> [WorkspaceRootShellProjection],
        rootChanges: AnyPublisher<Void, Never>,
        gitContextLookup: @escaping @MainActor (String) -> GitWorktreeContextSummary? = { _ in nil },
        gitContextChanges: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher(),
        codemapStatusLookup: @escaping @MainActor (UUID) -> WorkspaceCodemapRootStatusSnapshot? = { _ in nil },
        codemapStatusChanges: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher(),
        setCodemapSuspended: @escaping @MainActor (UUID, Bool) async -> Void = { _, _ in },
        workspaceManager: WorkspaceManagerViewModel,
        windowID: Int
    ) {
        self.rootProjections = rootProjections
        self.rootChanges = rootChanges
        self.gitContextLookup = gitContextLookup
        self.gitContextChanges = gitContextChanges
        self.codemapStatusLookup = codemapStatusLookup
        self.codemapStatusChanges = codemapStatusChanges
        self.setCodemapSuspended = setCodemapSuspended
        self.workspaceManager = workspaceManager
        self.windowID = windowID

        resnapshotRootRows()
        resnapshotWorkspaceMetadata()
        observeInputs()
    }

    deinit {
        rootRowsResnapshotTask?.cancel()
        workspaceMetadataResnapshotTask?.cancel()
    }

    static func rows(
        from projections: [WorkspaceRootShellProjection],
        gitContextLookup: (String) -> GitWorktreeContextSummary? = { _ in nil },
        codemapStatusLookup: (UUID) -> WorkspaceCodemapRootStatusSnapshot? = { _ in nil }
    ) -> [AgentWorkspaceRootRow] {
        let rootCount = projections.count
        return projections.enumerated().map { index, projection in
            AgentWorkspaceRootRow(
                id: projection.id,
                name: projection.name,
                fullPath: projection.fullPath,
                standardizedFullPath: projection.standardizedFullPath,
                isPrimary: rootCount > 1 && index == 0,
                canMoveUp: rootCount > 1 && index > 0,
                canMoveDown: rootCount > 1 && index < rootCount - 1,
                gitContext: gitContextLookup(projection.standardizedFullPath),
                codemap: AgentWorkspaceCodemapPresentation.make(codemapStatusLookup(projection.id))
            )
        }
    }

    func addFolder() async throws {
        try await workspaceManager.pickFolderAndOpenWorkspace(
            title: "Add Folder",
            message: "Choose a folder to add to your workspace.",
            behavior: .addToActiveOrCreateNew
        )
    }

    func exitWorkspace() async {
        await workspaceManager.saveAndExitToFallback()
    }

    func removeRoot(rowID: UUID) {
        guard let projection = currentProjection(for: rowID) else { return }
        Task { [workspaceManager] in
            await workspaceManager.removeActiveWorkspaceRoot(path: projection.fullPath)
        }
    }

    func moveRootUp(rowID: UUID) {
        guard let projection = currentProjection(for: rowID) else { return }
        let visibleRootOrder = rootProjections().map(\.fullPath)
        Task { [workspaceManager] in
            await workspaceManager.moveActiveWorkspaceRoot(
                path: projection.fullPath,
                direction: .up,
                visibleRootOrder: visibleRootOrder
            )
        }
    }

    func moveRootDown(rowID: UUID) {
        guard let projection = currentProjection(for: rowID) else { return }
        let visibleRootOrder = rootProjections().map(\.fullPath)
        Task { [workspaceManager] in
            await workspaceManager.moveActiveWorkspaceRoot(
                path: projection.fullPath,
                direction: .down,
                visibleRootOrder: visibleRootOrder
            )
        }
    }

    func toggleCodemapGeneration(rowID: UUID) async {
        guard !codemapActionRootIDs.contains(rowID),
              let row = rootRows.first(where: { $0.id == rowID }),
              row.codemap.canToggle
        else { return }
        codemapActionRootIDs.insert(rowID)
        defer { codemapActionRootIDs.remove(rowID) }
        await setCodemapSuspended(rowID, !row.codemap.isPaused)
        resnapshotRootRows()
    }

    func isCodemapActionPending(rowID: UUID) -> Bool {
        codemapActionRootIDs.contains(rowID)
    }

    private func observeInputs() {
        rootChanges
            .sink { [weak self] in
                Task { @MainActor in
                    self?.scheduleRootRowsResnapshot()
                }
            }
            .store(in: &cancellables)

        gitContextChanges
            .sink { [weak self] in
                Task { @MainActor in
                    self?.scheduleRootRowsResnapshot()
                }
            }
            .store(in: &cancellables)

        codemapStatusChanges
            .sink { [weak self] in
                Task { @MainActor in
                    self?.scheduleRootRowsResnapshot()
                }
            }
            .store(in: &cancellables)

        workspaceManager.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleWorkspaceMetadataResnapshot()
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleRootRowsResnapshot() {
        rootRowsResnapshotTask?.cancel()
        rootRowsResnapshotTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.resnapshotRootRows()
            }
        }
    }

    private func scheduleWorkspaceMetadataResnapshot() {
        workspaceMetadataResnapshotTask?.cancel()
        workspaceMetadataResnapshotTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.resnapshotWorkspaceMetadata()
            }
        }
    }

    private func resnapshotRootRows() {
        let nextRootRows = Self.rows(
            from: rootProjections(),
            gitContextLookup: gitContextLookup,
            codemapStatusLookup: codemapStatusLookup
        )

        if rootRows != nextRootRows {
            rootRows = nextRootRows
        }
    }

    private func resnapshotWorkspaceMetadata() {
        let nextWorkspaceLabel = Self.workspaceLabel(for: workspaceManager.activeWorkspace)
        let nextIsExitDisabled = workspaceManager.activeWorkspace?.isSystemWorkspace ?? true

        if workspaceLabel != nextWorkspaceLabel {
            workspaceLabel = nextWorkspaceLabel
        }
        if isExitDisabled != nextIsExitDisabled {
            isExitDisabled = nextIsExitDisabled
        }
    }

    private func currentProjection(for rowID: UUID) -> WorkspaceRootShellProjection? {
        rootProjections().first { $0.id == rowID }
    }

    private static func workspaceLabel(for workspace: WorkspaceModel?) -> String {
        guard let workspace, !workspace.isSystemWorkspace else { return "No Workspace" }
        let name = workspace.name
        return name.count > 16 ? String(name.prefix(16)) + "…" : name
    }
}
