import Combine

@MainActor
final class AgentContextDrawerPresentationStore: ObservableObject {
    @Published private(set) var isPresented = false

    func present() {
        isPresented = true
    }

    func close() {
        isPresented = false
    }
}

@MainActor
final class AgentContextDrawerDetailStore: ObservableObject {
    @Published var activeTab: AgentContextDrawerUIStore.Tab = .files
    @Published var filesSubtab: AgentContextDrawerUIStore.FilesSubtab = .files
    @Published var fileFilterText = ""
    @Published var selectionSort: AgentContextDrawerUIStore.SelectionSort = .tokensDescending
}

@MainActor
final class AgentContextDrawerUIStore {
    enum Tab: String, CaseIterable, Equatable {
        case files
        case builder
        case prompt
    }

    enum FilesSubtab: String, CaseIterable, Equatable {
        case files
        case codemaps
    }

    enum SelectionSort: String, CaseIterable, Identifiable, Equatable {
        case nameAscending
        case nameDescending
        case tokensDescending
        case tokensAscending

        var id: Self {
            self
        }

        var label: String {
            switch self {
            case .nameAscending: "Name A→Z"
            case .nameDescending: "Name Z→A"
            case .tokensDescending: "Tokens ↓"
            case .tokensAscending: "Tokens ↑"
            }
        }

        func sortedRows(_ rows: [AgentContextExportRow]) -> [AgentContextExportRow] {
            rows.sorted(by: areInIncreasingOrder)
        }

        func areInIncreasingOrder(_ lhs: AgentContextExportRow, _ rhs: AgentContextExportRow) -> Bool {
            switch self {
            case .nameAscending:
                if let ordering = Self.stringOrdering(lhs.displayName, rhs.displayName, ascending: true) {
                    return ordering
                }
                if let ordering = Self.stringOrdering(lhs.displayPath, rhs.displayPath, ascending: true) {
                    return ordering
                }
                return Self.tieBreakAfterNameAndPath(lhs, rhs)
            case .nameDescending:
                if let ordering = Self.stringOrdering(lhs.displayName, rhs.displayName, ascending: false) {
                    return ordering
                }
                if let ordering = Self.stringOrdering(lhs.displayPath, rhs.displayPath, ascending: false) {
                    return ordering
                }
                return Self.tieBreakAfterNameAndPath(lhs, rhs)
            case .tokensDescending:
                if lhs.metrics.tokenSortKey != rhs.metrics.tokenSortKey {
                    return lhs.metrics.tokenSortKey > rhs.metrics.tokenSortKey
                }
                return Self.tieBreakAfterTokens(lhs, rhs)
            case .tokensAscending:
                if lhs.metrics.tokenSortKey != rhs.metrics.tokenSortKey {
                    return lhs.metrics.tokenSortKey < rhs.metrics.tokenSortKey
                }
                return Self.tieBreakAfterTokens(lhs, rhs)
            }
        }

        private static func stringOrdering(_ lhs: String, _ rhs: String, ascending: Bool) -> Bool? {
            guard lhs != rhs else { return nil }
            return ascending
                ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
                : rhs.utf8.lexicographicallyPrecedes(lhs.utf8)
        }

        private static func tieBreakAfterTokens(_ lhs: AgentContextExportRow, _ rhs: AgentContextExportRow) -> Bool {
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            if let ordering = stringOrdering(lhs.displayName, rhs.displayName, ascending: true) { return ordering }
            if let ordering = stringOrdering(lhs.displayPath, rhs.displayPath, ascending: true) { return ordering }
            return tieBreakAfterNameAndPath(lhs, rhs)
        }

        private static func tieBreakAfterNameAndPath(_ lhs: AgentContextExportRow, _ rhs: AgentContextExportRow) -> Bool {
            if lhs.metrics.tokenSortKey != rhs.metrics.tokenSortKey {
                return lhs.metrics.tokenSortKey > rhs.metrics.tokenSortKey
            }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            if lhs.rootID != rhs.rootID { return lhs.rootID.uuidString < rhs.rootID.uuidString }
            return lhs.id.fileID.uuidString < rhs.id.fileID.uuidString
        }
    }

    let presentation = AgentContextDrawerPresentationStore()
    let detail = AgentContextDrawerDetailStore()

    var isPresented: Bool {
        presentation.isPresented
    }

    var activeTab: Tab {
        get { detail.activeTab }
        set { detail.activeTab = newValue }
    }

    var filesSubtab: FilesSubtab {
        get { detail.filesSubtab }
        set { detail.filesSubtab = newValue }
    }

    var fileFilterText: String {
        get { detail.fileFilterText }
        set { detail.fileFilterText = newValue }
    }

    var selectionSort: SelectionSort {
        get { detail.selectionSort }
        set { detail.selectionSort = newValue }
    }

    func open(tab: Tab? = nil) {
        if let tab, detail.activeTab != tab {
            detail.activeTab = tab
        }
        presentation.present()
    }

    func close() {
        presentation.close()
    }

    func toggle(tab: Tab? = nil) {
        if presentation.isPresented {
            if let tab, detail.activeTab != tab {
                detail.activeTab = tab
            } else {
                close()
            }
        } else {
            open(tab: tab)
        }
    }
}
