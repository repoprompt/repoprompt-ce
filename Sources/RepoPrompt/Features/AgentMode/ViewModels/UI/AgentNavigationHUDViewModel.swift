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

        if item.windowID == currentWindow.windowID {
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
            AgentNavigationHUDSnapshotBuilder.allAgentsSnapshot()
        }
        if nextSnapshot != snapshot {
            snapshot = nextSnapshot
        }
    }

    private func rebuildFilteredItems(preserveSelection: Bool) {
        let previousSelection = preserveSelection ? selectedItemID : nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = Self.searchTokens(in: trimmed)
        let corpus = displayCorpus(searching: !tokens.isEmpty)
        let matchingItems: [AgentNavigationHUDItem] = if tokens.isEmpty {
            corpus
        } else {
            corpus.filter { item in Self.matches(item, tokens: tokens) }
        }
        if tokens.isEmpty, snapshot.mode == .allAgents, matchingItems.count > AgentNavigationHUDSnapshotBuilder.allAgentsCap {
            let cappedItems = Array(matchingItems.prefix(AgentNavigationHUDSnapshotBuilder.allAgentsCap))
            if filteredItems != cappedItems {
                filteredItems = cappedItems
            }
            isShowingLimitedResults = true
        } else {
            if filteredItems != matchingItems {
                filteredItems = matchingItems
            }
            isShowingLimitedResults = false
        }

        if let previousSelection,
           filteredItems.contains(where: { $0.id == previousSelection })
        {
            selectedItemID = previousSelection
        } else {
            selectedItemID = filteredItems.first?.id
        }
    }

    private var displayCorpus: [AgentNavigationHUDItem] {
        displayCorpus(searching: false)
    }

    private func displayCorpus(searching: Bool) -> [AgentNavigationHUDItem] {
        if searching {
            return snapshot.items
        }
        if showSubagents {
            return snapshot.items.filter { $0.depth <= AgentNavigationHUDSnapshotBuilder.maxVisibleDepth }
        }
        return snapshot.items.filter { !$0.isSubagent }
    }

    private nonisolated static func matches(_ item: AgentNavigationHUDItem, tokens: [String]) -> Bool {
        tokens.allSatisfy { token in
            item.metadataSearchText.contains { field in
                field.localizedCaseInsensitiveContains(token)
            }
        }
    }

    nonisolated static func searchTokens(in query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false

        for character in query {
            if character == "\"" {
                if inQuote {
                    appendToken(&tokens, current)
                    current = ""
                } else {
                    appendToken(&tokens, current)
                    current = ""
                }
                inQuote.toggle()
            } else if character.isWhitespace, !inQuote {
                appendToken(&tokens, current)
                current = ""
            } else {
                current.append(character)
            }
        }
        appendToken(&tokens, current)
        return tokens
    }

    private nonisolated static func appendToken(_ tokens: inout [String], _ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tokens.append(trimmed)
        }
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
