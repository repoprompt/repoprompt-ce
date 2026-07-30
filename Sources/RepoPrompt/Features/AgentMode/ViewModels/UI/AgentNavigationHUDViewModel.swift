import Foundation

@MainActor
final class AgentNavigationHUDViewModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var snapshot = AgentNavigationHUDSnapshot(
        mode: .currentWindow,
        title: AgentNavigationHUDMode.currentWindow.title,
        items: []
    )
    @Published var query = "" {
        didSet { rebuildFilteredItems(preserveSelection: true) }
    }

    @Published private(set) var filteredItems: [AgentNavigationHUDItem] = []
    @Published private(set) var selectedItemID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRouting = false
    @Published private(set) var isShowingLimitedResults = false
    @Published private(set) var showSubagents = false

    var selectedIndex: Int {
        guard let selectedItemID,
              let index = filteredItems.firstIndex(where: { $0.id == selectedItemID })
        else { return 0 }
        return index
    }

    var totalItemCount: Int {
        displayCorpus.count
    }

    var needsAttentionCount: Int {
        displayCorpus.count(where: { $0.attentionState != nil || $0.hasHiddenSubagentAttention })
    }

    var hiddenSubagentCount: Int {
        snapshot.items.count { $0.isSubagent }
    }

    var showsSubagentToggleHint: Bool {
        queryIsEmpty && hiddenSubagentCount > 0
    }

    var queryIsEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func present(mode: AgentNavigationHUDMode, currentWindow: WindowState) {
        if isPresented, snapshot.mode == mode {
            dismiss()
            return
        }

        let shouldResetQuery = !isPresented
        errorMessage = nil
        refreshSnapshot(mode: mode, currentWindow: currentWindow)
        if shouldResetQuery {
            query = ""
        }
        isPresented = true
        rebuildFilteredItems(preserveSelection: !shouldResetQuery)
    }

    func setMode(_ mode: AgentNavigationHUDMode, currentWindow: WindowState) {
        guard snapshot.mode != mode else { return }
        errorMessage = nil
        refreshSnapshot(mode: mode, currentWindow: currentWindow)
        rebuildFilteredItems(preserveSelection: true)
    }

    func refresh(currentWindow: WindowState) {
        guard isPresented else { return }
        refreshSnapshot(mode: snapshot.mode, currentWindow: currentWindow)
        rebuildFilteredItems(preserveSelection: true)
    }

    func toggleSubagents() {
        showSubagents.toggle()
        errorMessage = nil
        rebuildFilteredItems(preserveSelection: true)
    }

    func dismiss() {
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

    private func refreshSnapshot(mode: AgentNavigationHUDMode, currentWindow: WindowState) {
        let nextSnapshot = switch mode {
        case .currentWindow:
            AgentNavigationHUDSnapshotBuilder.currentWindowSnapshot(windowState: currentWindow)
        case .allAgents:
            AgentNavigationHUDSnapshotBuilder.allAgentsSnapshot(currentWindow: currentWindow)
        }
        if nextSnapshot != snapshot {
            snapshot = nextSnapshot
        }
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

    private var displayCorpus: [AgentNavigationHUDItem] {
        displayCorpus(searching: false)
    }

    private func displayCorpus(searching: Bool) -> [AgentNavigationHUDItem] {
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
        corpus.enumerated().compactMap { index, item -> (Int, AgentSessionSearchScore, AgentNavigationHUDItem)? in
            guard let score = AgentSessionSearchMatcher.score(query: query, fields: item.searchFields) else { return nil }
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
