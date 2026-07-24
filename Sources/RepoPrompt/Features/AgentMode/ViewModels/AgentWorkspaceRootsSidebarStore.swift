import Combine
import Foundation

struct AgentWorkspaceCodemapPresentation: Equatable {
    enum State: Equatable {
        case pending
        case mapping
        case waiting
        case ready
        case paused
        case unavailable
    }

    enum Tone: Equatable {
        case accent
        case success
        case warning
        case secondary
    }

    let state: State
    /// Durable candidate coverage accepted by the projection catalog.
    let processedCandidateCount: UInt64
    /// Ephemeral candidates resolved locally in the active batch, expressed through the root.
    let locallyResolvedCandidateCountThroughRoot: UInt64?
    let totalCandidateCount: UInt64?

    static let pending = Self(
        state: .pending,
        processedCandidateCount: 0,
        locallyResolvedCandidateCountThroughRoot: nil,
        totalCandidateCount: nil
    )

    var tone: Tone {
        switch state {
        case .pending, .mapping: .accent
        case .waiting: .warning
        case .ready: .success
        case .paused, .unavailable: .secondary
        }
    }

    var isPaused: Bool {
        state == .paused
    }

    var canToggle: Bool {
        state != .unavailable
    }

    var isActivelyMapping: Bool {
        switch state {
        case .pending, .mapping: true
        case .waiting, .ready, .paused, .unavailable: false
        }
    }

    var showsProgress: Bool {
        switch state {
        case .pending, .mapping, .waiting: true
        case .ready, .paused, .unavailable: false
        }
    }

    var displayProcessedCandidateCount: UInt64 {
        let displayed = max(
            processedCandidateCount,
            locallyResolvedCandidateCountThroughRoot ?? 0
        )
        guard let totalCandidateCount else { return displayed }
        return min(displayed, totalCandidateCount)
    }

    var progressFraction: Double? {
        if state == .ready, totalCandidateCount == 0 { return 1 }
        guard let totalCandidateCount, totalCandidateCount > 0 else { return nil }
        let fraction = min(1, Double(displayProcessedCandidateCount) / Double(totalCandidateCount))
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
        switch state {
        case .pending: "Preparing…"
        case .mapping: percentageText.map { "Mapping \($0)" } ?? "Mapping…"
        case .waiting: percentageText.map { "Waiting at \($0)" } ?? "Waiting…"
        case .ready: "Mapped"
        case .paused: "Paused"
        case .unavailable: "Unavailable"
        }
    }

    var tooltip: String {
        switch state {
        case .pending:
            "Code Map generation is preparing."
        case .mapping:
            if let totalCandidateCount {
                "Code Map generation: \(displayProcessedCandidateCount) of \(totalCandidateCount) files processed for mapping (\(percentageText ?? "0%"))."
            } else {
                "Code Map generation is in progress."
            }
        case .waiting:
            "Code Map generation is waiting to continue."
        case .ready:
            "Code Map generation is complete: \(displayProcessedCandidateCount) files mapped."
        case .paused:
            "Paused for this loaded root. Resume to allow Code Map generation."
        case .unavailable:
            "Code Maps are unavailable because this root is not a Git repository."
        }
    }

    static func make(_ snapshot: WorkspaceCodemapRootStatusSnapshot?) -> Self {
        guard let snapshot else { return .pending }
        let state: State = switch snapshot.state {
        case .idle, .preparing: .pending
        case .generating: .mapping
        case .waiting: .waiting
        case .ready: .ready
        case .paused: .paused
        case .unavailable: .unavailable
        }
        return Self(
            state: state,
            processedCandidateCount: snapshot.processedCandidateCount,
            locallyResolvedCandidateCountThroughRoot: snapshot.locallyResolvedCandidateCountThroughRoot,
            totalCandidateCount: snapshot.totalCandidateCount
        )
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
