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
    private var includesArchivedSearchRows = false
    private var perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
    private var searchFieldsMemo: [String: (item: AgentNavigationHUDItem, fields: AgentSessionSearchFields)] = [:]

    #if DEBUG
        private(set) var test_searchFieldsMaterializationCount = 0

        func test_waitForSnapshot() async {
            await snapshotTask?.value
        }
    #endif

    var selectedIndex: Int {
        guard let selectedItemID,
              let index = filteredItems.firstIndex(where: { $0.id == selectedItemID })
        else { return 0 }
        return index
    }

    var totalItemCount: Int {
        snapshot.items.count { !$0.isArchived }
    }

    var needsAttentionCount: Int {
        snapshot.items.count(where: { !$0.isArchived && $0.attentionState != nil })
    }

    var hiddenSubagentCount: Int {
        snapshot.items.count { $0.isSubagent }
    }

    var showsSubagentToggleHint: Bool {
        roleFilter == .all && queryIsEmpty && hiddenSubagentCount > 0
    }

    var queryIsEmpty: Bool {
        AgentSessionSearchQuery.parse(query).isEmpty
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
        if isPresented, snapshot.mode == .allAgents, roleFilter == .all, !queryIsEmpty, !includesArchivedSearchRows {
            scheduleSnapshot()
        }
    }

    private func scheduleSnapshot(preserveSelection: Bool = true) {
        guard isPresented, snapshotTask == nil, snapshotLoader != nil else { return }
        let mode = snapshot.mode
        let previousSelection = preserveSelection ? selectedItemID : nil
        isLoadingSnapshot = true
        snapshotTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, isPresented, snapshot.mode == mode,
                  let snapshotLoader
            else { return }
            let includeArchived = mode == .allAgents && roleFilter == .all && !queryIsEmpty
            let next = snapshotLoader(mode, includeArchived)
            snapshotTask = nil
            includesArchivedSearchRows = includeArchived
            if next != snapshot { snapshot = next }
            let liveIDs = Set(next.items.map(\.id))
            searchFieldsMemo = searchFieldsMemo.filter { liveIDs.contains($0.key) }
            isLoadingSnapshot = false
            if selectedItemID == nil { selectedItemID = previousSelection }
            rebuildFilteredItems(preserveSelection: preserveSelection)
        }
    }

    func toggleSubagents() {
        guard roleFilter == .all else { return }
        showSubagents.toggle()
        errorMessage = nil
        rebuildFilteredItems(preserveSelection: true)
    }

    func dismiss() {
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotLoader = nil
        isLoadingSnapshot = false
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
        guard filteredItems.indices.contains(selectedIndex) else { return }
        await select(filteredItems[selectedIndex], currentWindow: currentWindow)
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
        let searchQuery = AgentSessionSearchQuery.parse(query)
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
        guard filteredItems.indices.contains(index) else { return }
        await select(filteredItems[index], currentWindow: currentWindow)
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
