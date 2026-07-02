import Combine
import Foundation

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

    init(
        id: UUID,
        name: String,
        fullPath: String,
        standardizedFullPath: String? = nil,
        isPrimary: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool,
        gitContext: GitWorktreeContextSummary? = nil,
        worktree: AgentWorktreeIndicator? = nil
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
            worktree: worktree
        )
    }
}

@MainActor
final class AgentWorkspaceRootsSidebarStore: ObservableObject {
    @Published private(set) var rootRows: [AgentWorkspaceRootRow] = []
    @Published private(set) var workspaceLabel = "No Workspace"
    @Published private(set) var isExitDisabled = true

    private let rootProjections: @MainActor () -> [WorkspaceRootShellProjection]
    private let rootChanges: AnyPublisher<Void, Never>
    private let gitContextLookup: @MainActor (String) -> GitWorktreeContextSummary?
    private let gitContextChanges: AnyPublisher<Void, Never>
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
        workspaceManager: WorkspaceManagerViewModel,
        windowID: Int
    ) {
        self.rootProjections = rootProjections
        self.rootChanges = rootChanges
        self.gitContextLookup = gitContextLookup
        self.gitContextChanges = gitContextChanges
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
        gitContextLookup: (String) -> GitWorktreeContextSummary? = { _ in nil }
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
                gitContext: gitContextLookup(projection.standardizedFullPath)
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
            gitContextLookup: gitContextLookup
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
