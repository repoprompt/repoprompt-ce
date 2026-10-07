import Foundation
import RepoPromptInstrumentation

@MainActor
final class AgentNavigationHUDViewModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var snapshot = AgentNavigationHUDSnapshot(
        mode: .currentWindow,
        title: AgentNavigationHUDMode.currentWindow.title,
        items: []
    )
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            parsedQuery = AgentSessionSearchQuery.parse(query)
            pendingSelection = nil
            ensureArchivedSearchRows()
            rebuildFilteredItems(preserveSelection: true)
        }
    }

    @Published private(set) var filteredItems: [AgentNavigationHUDItem] = []
    @Published private(set) var selectedItemID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRouting = false
    @Published private(set) var isShowingLimitedResults = false
    @Published private(set) var showSubagents = false
    @Published private(set) var roleFilter: AgentNavigationHUDRoleFilter = .all
    @Published private(set) var isLoadingSnapshot = false

    typealias SnapshotLoader = @MainActor (AgentNavigationHUDMode, Bool) -> AgentNavigationHUDSnapshot
    private var snapshotLoader: SnapshotLoader?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotTaskID: UUID?
    private var hasLoadedSnapshot = false
    private var parsedQuery = AgentSessionSearchQuery.parse("")
    private enum SelectionIntent {
        case highlighted
        case displayIndex(Int)
    }

    typealias SelectionAction = @MainActor (AgentNavigationHUDItem) async -> Void
    private var pendingSelection: (intent: SelectionIntent, action: SelectionAction)?
    private var includesArchivedSearchRows = false
    private var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    private var searchFieldsMemo: [String: (item: AgentNavigationHUDItem, fields: AgentSessionSearchFields)] = [:]

    #if DEBUG
        private(set) var test_searchFieldsMaterializationCount = 0

        func test_waitForSnapshot() async {
            await snapshotTask?.value
        }

        func test_cancelSnapshotTask() {
            snapshotTask?.cancel()
        }
    #endif

    var selectedIndex: Int {
        guard let selectedItemID,
              let index = filteredItems.firstIndex(where: { $0.id == selectedItemID })
        else { return 0 }
        return index
    }

    var totalItemCount: Int {
        displayCorpus(searching: false).count
    }

    var needsAttentionCount: Int {
        displayCorpus(searching: false).count { $0.attentionState != nil || $0.hasHiddenSubagentAttention }
    }

    var hiddenSubagentCount: Int {
        snapshot.items.count { $0.isSubagent }
    }

    var showsSubagentToggleHint: Bool {
        roleFilter == .all && !hasSearchTerms && hiddenSubagentCount > 0
    }

    var queryIsEmpty: Bool {
        // Esc clears any entered text, even text such as two quotes that parses to no tokens.
        parsedQuery.rawValue.isEmpty
    }

    var hasSearchTerms: Bool {
        !parsedQuery.isEmpty
    }

    var showsRoleFilter: Bool {
        roleFilter != .all || snapshot.items.contains { !$0.isArchived && ($0.overseenSessionCount > 0 || $0.isOverseen) }
    }

    var roleItemCount: Int {
        snapshot.items.count { !$0.isArchived && roleFilter.includes($0) }
    }

    var emptyTitle: String {
        guard roleFilter != .all else { return snapshot.mode.emptyTitle }
        let role = roleFilter == .overseers ? "overseer" : "overseen"
        return snapshot.mode == .currentWindow
            ? "No \(role) sessions in this window"
            : "No active or recent \(role) sessions across windows"
    }

    func setRoleFilter(_ filter: AgentNavigationHUDRoleFilter) {
        guard roleFilter != filter else { return }
        pendingSelection = nil
        roleFilter = filter
        errorMessage = nil
        ensureArchivedSearchRows()
        rebuildFilteredItems(preserveSelection: true)
    }

    func cycleRoleFilter(backward: Bool = false) {
        let filters = AgentNavigationHUDRoleFilter.allCases
        guard let index = filters.firstIndex(of: roleFilter) else { return }
        setRoleFilter(filters[(index + (backward ? filters.count - 1 : 1)) % filters.count])
    }

    func present(mode: AgentNavigationHUDMode, currentWindow: WindowState) {
        perfRecorder = currentWindow.agentModeViewModel.perfRecorder
        present(mode: mode, loadSnapshot: Self.loader(for: currentWindow))
    }

    /// Publish the shell before doing any sidebar projection work. One cancellable,
    /// coalesced main-actor turn loads raw rows; normalization stays query-only.
    func present(mode: AgentNavigationHUDMode, loadSnapshot: @escaping SnapshotLoader) {
        if isPresented, snapshot.mode == mode {
            dismiss()
            return
        }
        let shouldResetQuery = !isPresented
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotTaskID = nil
        pendingSelection = nil
        hasLoadedSnapshot = false
        snapshotLoader = loadSnapshot
        snapshot = AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: [])
        includesArchivedSearchRows = false
        errorMessage = nil
        if shouldResetQuery { query = "" }
        isPresented = true
        scheduleSnapshot(preserveSelection: !shouldResetQuery)
        filteredItems = []
        isShowingLimitedResults = false
    }

    func setMode(_ mode: AgentNavigationHUDMode, currentWindow: WindowState) {
        guard snapshot.mode != mode else { return }
        present(mode: mode, currentWindow: currentWindow)
    }

    func refresh(currentWindow: WindowState) {
        guard isPresented else { return }
        snapshotLoader = Self.loader(for: currentWindow)
        refresh()
    }

    func refresh() {
        scheduleSnapshot()
    }

    /// Activity, unread counts and notices share the oversight notification. Resolve
    /// only this owner's exact roles, without rebuilding sidebar rows in any window.
    func refreshOversightRoles(from owner: AgentModeViewModel) {
        guard isPresented, hasLoadedSnapshot else { return }
        let items = snapshot.items.filter { $0.windowID == owner.windowID && !$0.isArchived }
        let expectedSessionIDs = Dictionary(items.compactMap { item in
            item.sessionID.map { (item.tabID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        refreshIfOversightRolesChanged(
            windowID: owner.windowID,
            roles: owner.agentSessionLinkOversightRoles(expectedSessionIDs: expectedSessionIDs)
        )
    }

    func refreshIfOversightRolesChanged(windowID: Int, roles: [UUID: (overseeingCount: Int, isOverseen: Bool)]) {
        guard isPresented, hasLoadedSnapshot else { return }
        let changed = snapshot.items.contains { item in
            guard item.windowID == windowID, !item.isArchived else { return false }
            let role = roles[item.tabID] ?? (0, false)
            return item.overseenSessionCount != role.overseeingCount || item.isOverseen != role.isOverseen
        }
        if changed { refresh() }
    }

    private static func loader(for currentWindow: WindowState) -> SnapshotLoader {
        { [weak currentWindow] mode, includeArchived in
            guard let currentWindow else { return AgentNavigationHUDSnapshot(mode: mode, title: mode.title, items: []) }
            return switch mode {
            case .currentWindow:
                AgentNavigationHUDSnapshotBuilder.currentWindowSnapshot(windowState: currentWindow)
            case .allAgents:
                AgentNavigationHUDSnapshotBuilder.allAgentsSnapshot(currentWindow: currentWindow, includeArchived: includeArchived)
            }
        }
    }

    private func ensureArchivedSearchRows() {
        if isPresented, snapshot.mode == .allAgents, roleFilter == .all, !parsedQuery.isEmpty, !includesArchivedSearchRows {
            scheduleSnapshot()
        }
    }

    private func scheduleSnapshot(preserveSelection: Bool = true) {
        guard isPresented, snapshotTask == nil, snapshotLoader != nil else { return }
        let mode = snapshot.mode
        let taskID = UUID()
        snapshotTaskID = taskID
        let previousSelection = preserveSelection ? selectedItemID : nil
        // Refreshes retain both previous rows and recoverable empty-filter states.
        isLoadingSnapshot = !hasLoadedSnapshot
        snapshotTask = Task { [weak self] in
            await Task.yield()
            guard let self, snapshotTaskID == taskID else { return }
            guard !Task.isCancelled, isPresented, snapshot.mode == mode,
                  let snapshotLoader
            else {
                snapshotTask = nil
                snapshotTaskID = nil
                isLoadingSnapshot = false
                pendingSelection = nil
                return
            }
            let includeArchived = mode == .allAgents && roleFilter == .all && !parsedQuery.isEmpty
            let next = snapshotLoader(mode, includeArchived)
            snapshotTask = nil
            snapshotTaskID = nil
            includesArchivedSearchRows = includeArchived
            if next != snapshot { snapshot = next }
            let liveIDs = Set(next.items.map(\.id))
            searchFieldsMemo = searchFieldsMemo.filter { liveIDs.contains($0.key) }
            isLoadingSnapshot = false
            hasLoadedSnapshot = true
            if selectedItemID == nil { selectedItemID = previousSelection }
            rebuildFilteredItems(preserveSelection: preserveSelection)
            if let pending = pendingSelection {
                pendingSelection = nil
                await select(intent: pending.intent, using: pending.action)
            }
        }
    }

    func toggleSubagents() {
        guard roleFilter == .all else { return }
        pendingSelection = nil
        showSubagents.toggle()
        errorMessage = nil
        rebuildFilteredItems(preserveSelection: true)
    }

    func dismiss() {
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotTaskID = nil
        snapshotLoader = nil
        isLoadingSnapshot = false
        hasLoadedSnapshot = false
        pendingSelection = nil
        searchFieldsMemo.removeAll()
        isPresented = false
        errorMessage = nil
        query = ""
        selectedItemID = nil
        isRouting = false
        rebuildFilteredItems(preserveSelection: false)
    }

    @discardableResult
    func clearQueryOrDismiss() -> Bool {
        if !queryIsEmpty {
            query = ""
            errorMessage = nil
            return false
        }
        dismiss()
        return true
    }

    func moveSelection(by delta: Int) {
        let count = filteredItems.count
        guard count > 0 else {
            selectedItemID = nil
            return
        }
        let current = selectedIndex
        let next = (current + delta + count) % count
        selectedItemID = filteredItems[next].id
    }

    func moveSelection(to itemID: String) {
        guard filteredItems.contains(where: { $0.id == itemID }) else { return }
        selectedItemID = itemID
    }

    func selectHighlighted(currentWindow: WindowState) async {
        await selectHighlighted { [weak currentWindow, weak self] item in
            guard let currentWindow, let self else { return }
            await select(item, currentWindow: currentWindow)
        }
    }

    func selectHighlighted(using action: @escaping SelectionAction) async {
        await select(intent: .highlighted, using: action)
    }

    private func select(intent: SelectionIntent, using action: @escaping SelectionAction) async {
        guard isPresented else { return }
        if isLoadingSnapshot {
            // Last pick wins; do not resolve an index against the empty opening shell.
            pendingSelection = (intent, action)
            return
        }
        let index = switch intent {
        case .highlighted: selectedIndex
        case let .displayIndex(index): index
        }
        guard filteredItems.indices.contains(index) else { return }
        await action(filteredItems[index])
    }

    func select(_ item: AgentNavigationHUDItem, currentWindow: WindowState) async {
        guard !isRouting else { return }
        isRouting = true
        defer { isRouting = false }

        if item.windowID == currentWindow.windowID, !item.isArchived {
            guard currentWindow.promptManager.currentComposeTabs.contains(where: { $0.id == item.tabID }) else {
                errorMessage = "That Agent session changed. Results refreshed."
                refresh(currentWindow: currentWindow)
                return
            }
            dismiss()
            await currentWindow.promptManager.switchComposeTab(item.tabID)
            return
        }

        dismiss()
        _ = await AppDeepLinkRouter.shared.route(agentSession: AgentSessionDeepLinkRoute(
            windowID: item.windowID,
            workspaceID: item.workspaceID,
            tabID: item.tabID,
            sessionID: item.sessionID
        ))
    }

    private func rebuildFilteredItems(preserveSelection: Bool) {
        let previousSelection = preserveSelection ? selectedItemID : nil
        let searchQuery = parsedQuery
        let corpus = displayCorpus(searching: !searchQuery.isEmpty)
        let matchingItems: [AgentNavigationHUDItem] = if searchQuery.isEmpty {
            corpus
        } else {
            rankedMatches(for: searchQuery, in: corpus)
        }
        if searchQuery.isEmpty, snapshot.mode == .allAgents, matchingItems.count > AgentNavigationHUDSnapshotBuilder.allAgentsCap {
            let cappedItems = Array(matchingItems.prefix(AgentNavigationHUDSnapshotBuilder.allAgentsCap))
            if filteredItems != cappedItems {
                filteredItems = cappedItems
            }
            if !isShowingLimitedResults {
                isShowingLimitedResults = true
            }
        } else {
            if filteredItems != matchingItems {
                filteredItems = matchingItems
            }
            if isShowingLimitedResults {
                isShowingLimitedResults = false
            }
        }

        let nextSelectedItemID: String? = if let previousSelection,
                                             filteredItems.contains(where: { $0.id == previousSelection })
        {
            previousSelection
        } else {
            filteredItems.first?.id
        }
        if selectedItemID != nextSelectedItemID {
            selectedItemID = nextSelectedItemID
        }
    }

    private func displayCorpus(searching: Bool) -> [AgentNavigationHUDItem] {
        if roleFilter != .all {
            // Roles flatten the corpus at every depth, even with an empty query.
            // Archived sessions have no live endpoint and never participate.
            return snapshot.items.filter { roleFilter.includes($0) }
        }
        if searching {
            return snapshot.items
        }
        let visible = snapshot.items.filter { !$0.isArchived }
        if showSubagents {
            return visible.filter { $0.depth <= AgentNavigationHUDSnapshotBuilder.maxVisibleDepth }
        }
        return visible.filter { !$0.isSubagent }
    }

    func selectItem(atDisplayIndex index: Int, currentWindow: WindowState) async {
        await selectItem(atDisplayIndex: index) { [weak currentWindow, weak self] item in
            guard let currentWindow, let self else { return }
            await select(item, currentWindow: currentWindow)
        }
    }

    func selectItem(atDisplayIndex index: Int, using action: @escaping SelectionAction) async {
        await select(intent: .displayIndex(index), using: action)
    }

    private func rankedMatches(
        for query: AgentSessionSearchQuery,
        in corpus: [AgentNavigationHUDItem]
    ) -> [AgentNavigationHUDItem] {
        #if DEBUG
            let startMS = perfRecorder.timestampMSIfEnabled()
            let previousCount = test_searchFieldsMaterializationCount
            defer {
                perfRecorder.durationEvent("hud.search.match", startMS: startMS, fields: [
                    "rowCount": String(corpus.count),
                    "materializedCount": String(test_searchFieldsMaterializationCount - previousCount)
                ])
            }
        #endif
        return corpus.enumerated().compactMap { index, item -> (Int, AgentSessionSearchScore, AgentNavigationHUDItem)? in
            let fields: AgentSessionSearchFields
            if let cached = searchFieldsMemo[item.id], cached.item == item {
                fields = cached.fields
            } else {
                fields = item.searchFields
                searchFieldsMemo[item.id] = (item, fields)
                #if DEBUG
                    test_searchFieldsMaterializationCount += 1
                #endif
            }
            guard let score = AgentSessionSearchMatcher.score(query: query, fields: fields) else { return nil }
            return (index, score, item)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        .map(\.2)
    }

    private static func message(for result: AgentSessionRouteResult) -> String {
        switch result {
        case .routed:
            "jumped"
        case .workspaceUnavailable:
            "workspace unavailable"
        case let .workspaceSwitchBlocked(message):
            message ?? "workspace switch blocked"
        case .tabUnavailable:
            "session tab unavailable"
        case .sessionUnavailable:
            "session unavailable"
        case .sessionMismatch:
            "session changed"
        case .blockedByActiveDifferentSession:
            "another session is active"
        }
    }
}
