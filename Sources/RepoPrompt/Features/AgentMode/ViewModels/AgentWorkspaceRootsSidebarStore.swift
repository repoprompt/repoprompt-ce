import Combine
import Foundation

/// Subtle per-root codemap scanning/loading state rendered under the root
/// identity line in the Agent Mode workspace roots sidebar.
enum AgentRootCodemapProgressDisplayState: Equatable {
    /// Projection scan in flight; determinate when `total` is known.
    case scanning(processed: UInt64, total: UInt64?)
    /// Projection coverage complete for the root's current generation.
    case ready
    /// The global code maps kill-switch is on; overrides any activity.
    case disabledGlobally

    var displayText: String {
        switch self {
        case let .scanning(processed, total?):
            "Codemaps \(processed)/\(total)"
        case .scanning:
            "Codemaps scanning…"
        case .ready:
            "Codemaps ready"
        case .disabledGlobally:
            "Codemaps disabled globally"
        }
    }

    var accessibilityText: String {
        switch self {
        case let .scanning(processed, total?):
            "Codemaps scanning, \(processed) of \(total) files processed"
        case let .scanning(processed, nil):
            "Codemaps scanning, \(processed) files processed"
        case .ready:
            "Codemaps ready"
        case .disabledGlobally:
            "Codemaps disabled globally"
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
    /// Per-root codemap progress display states keyed by root UUID
    /// (`AgentWorkspaceRootRow.id`). Published separately from `rootRows` so
    /// progress ticks never rebuild rows or disturb row identity/ordering.
    @Published private(set) var codemapProgressByRootID: [UUID: AgentRootCodemapProgressDisplayState] = [:]

    private let rootProjections: @MainActor () -> [WorkspaceRootShellProjection]
    private let rootChanges: AnyPublisher<Void, Never>
    private let gitContextLookup: @MainActor (String) -> GitWorktreeContextSummary?
    private let gitContextChanges: AnyPublisher<Void, Never>
    private let codemapActivityLookup: @MainActor () -> [UUID: WorkspaceRootCodemapActivity]
    private let codemapActivityChanges: AnyPublisher<Void, Never>
    private let codemapsGloballyDisabled: AnyPublisher<Bool, Never>
    private let codemapActivityThrottleMilliseconds: Int
    private let workspaceManager: WorkspaceManagerViewModel
    let windowID: Int

    private var cancellables: Set<AnyCancellable> = []
    private var rootRowsResnapshotTask: Task<Void, Never>?
    private var workspaceMetadataResnapshotTask: Task<Void, Never>?
    private var isCodemapsGloballyDisabled = false

    var workspaceManagerForPicker: WorkspaceManagerViewModel {
        workspaceManager
    }

    init(
        rootProjections: @escaping @MainActor () -> [WorkspaceRootShellProjection],
        rootChanges: AnyPublisher<Void, Never>,
        gitContextLookup: @escaping @MainActor (String) -> GitWorktreeContextSummary? = { _ in nil },
        gitContextChanges: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher(),
        codemapActivityLookup: @escaping @MainActor () -> [UUID: WorkspaceRootCodemapActivity] = { [:] },
        codemapActivityChanges: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher(),
        codemapsGloballyDisabled: AnyPublisher<Bool, Never>? = nil,
        initialCodemapsGloballyDisabled: Bool? = nil,
        codemapActivityThrottleMilliseconds: Int = 150,
        workspaceManager: WorkspaceManagerViewModel,
        windowID: Int
    ) {
        self.rootProjections = rootProjections
        self.rootChanges = rootChanges
        self.gitContextLookup = gitContextLookup
        self.gitContextChanges = gitContextChanges
        self.codemapActivityLookup = codemapActivityLookup
        self.codemapActivityChanges = codemapActivityChanges
        self.codemapsGloballyDisabled = codemapsGloballyDisabled
            ?? GlobalSettingsStore.shared.$codeMapsGloballyDisabled.eraseToAnyPublisher()
        isCodemapsGloballyDisabled = initialCodemapsGloballyDisabled
            ?? (codemapsGloballyDisabled == nil ? GlobalSettingsStore.shared.globalCodeMapsDisabled() : false)
        self.codemapActivityThrottleMilliseconds = max(0, codemapActivityThrottleMilliseconds)
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

    /// Pure mapping from visible root projections + per-root activity to
    /// display states. Progress is joined strictly by root UUID; activity
    /// entries whose IDs do not match a visible projection (for example hidden
    /// physical worktree session roots) are dropped. Global disable wins.
    static func codemapProgressStates(
        for projections: [WorkspaceRootShellProjection],
        activityByRootID: [UUID: WorkspaceRootCodemapActivity],
        globallyDisabled: Bool
    ) -> [UUID: AgentRootCodemapProgressDisplayState] {
        if globallyDisabled {
            return Dictionary(uniqueKeysWithValues: projections.map { ($0.id, .disabledGlobally) })
        }
        var states: [UUID: AgentRootCodemapProgressDisplayState] = [:]
        for projection in projections {
            switch activityByRootID[projection.id] {
            case let .scanning(processed, total):
                states[projection.id] = .scanning(processed: processed, total: total)
            case .ready:
                states[projection.id] = .ready
            case nil:
                break
            }
        }
        return states
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

        codemapActivityChanges
            .throttle(
                for: .milliseconds(codemapActivityThrottleMilliseconds),
                scheduler: DispatchQueue.main,
                latest: true
            )
            .sink { [weak self] in
                Task { @MainActor in
                    self?.resnapshotCodemapProgress()
                }
            }
            .store(in: &cancellables)

        codemapsGloballyDisabled
            .removeDuplicates()
            .sink { [weak self] disabled in
                Task { @MainActor in
                    guard let self, self.isCodemapsGloballyDisabled != disabled else { return }
                    self.isCodemapsGloballyDisabled = disabled
                    self.resnapshotCodemapProgress()
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
        resnapshotCodemapProgress()
    }

    private func resnapshotCodemapProgress() {
        let next = Self.codemapProgressStates(
            for: rootProjections(),
            activityByRootID: codemapActivityLookup(),
            globallyDisabled: isCodemapsGloballyDisabled
        )
        if codemapProgressByRootID != next {
            codemapProgressByRootID = next
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
