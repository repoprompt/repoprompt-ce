import Foundation

struct AgentSidebarSelectionModifiers: OptionSet {
    let rawValue: Int

    static let command = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
}

enum AgentSidebarSelectionIdentity: Hashable {
    case active(tabID: UUID)
    case archived(stashedTabID: UUID, tabID: UUID)

    var tabID: UUID {
        switch self {
        case let .active(tabID), let .archived(_, tabID): tabID
        }
    }
}

enum AgentSidebarSelectionGesture: Equatable {
    case primary
    case toggle
    case range

    init(modifiers: AgentSidebarSelectionModifiers) {
        if modifiers.contains(.shift) {
            self = .range
        } else if modifiers.contains(.command) {
            self = .toggle
        } else {
            self = .primary
        }
    }
}

enum AgentSidebarSelectionGestureDisposition: Equatable {
    case activate
    case selectionChanged
    case ignored
}

enum AgentSidebarBulkActionKind: String, Equatable {
    case delete
    case stash
    case pin
    case unpin

    var rowProgressAccessibilityLabel: String {
        switch self {
        case .delete: "Deleting chat"
        case .stash: "Stashing chat"
        case .pin: "Pinning chat"
        case .unpin: "Unpinning chat"
        }
    }
}

enum AgentSidebarBulkActionOrigin: Equatable {
    case selection
    case command
}

enum AgentSidebarCommandProgressPlacement: Equatable {
    case row
    case archivedHeader
}

struct AgentSidebarBulkActionOperation: Equatable {
    let token: UUID
    let workspaceID: UUID
    let kind: AgentSidebarBulkActionKind
    let origin: AgentSidebarBulkActionOrigin
    let presentationTargets: Set<AgentSidebarSelectionIdentity>
    let commandProgressPlacement: AgentSidebarCommandProgressPlacement?
    var commandRowProgressRetired = false

    var targetCount: Int {
        presentationTargets.count
    }
}

struct AgentSidebarBulkActionNotice: Equatable {
    enum Severity: Equatable {
        case information
        case warning
        case error
    }

    let severity: Severity
    let title: String
    let message: String
}

struct AgentSidebarSelectionState: Equatable {
    var workspaceID: UUID?
    var selectedIdentities: Set<AgentSidebarSelectionIdentity> = []
    var anchor: AgentSidebarSelectionIdentity?
    var inFlightAction: AgentSidebarBulkActionOperation?
    var notice: AgentSidebarBulkActionNotice?
    var revision = 0

    var showsSelectionPresentation: Bool {
        !selectedIdentities.isEmpty || inFlightAction?.origin == .selection
    }

    var isMutationInFlight: Bool {
        inFlightAction != nil
    }

    func commandRowProgressOperation(
        for identity: AgentSidebarSelectionIdentity,
        workspaceID: UUID?
    ) -> AgentSidebarBulkActionOperation? {
        guard let operation = inFlightAction,
              operation.origin == .command,
              operation.workspaceID == workspaceID,
              operation.commandProgressPlacement == .row,
              !operation.commandRowProgressRetired,
              operation.presentationTargets.contains(identity)
        else { return nil }
        return operation
    }

    func commandFallbackProgressOperation(
        existingIdentities: Set<AgentSidebarSelectionIdentity>,
        renderedIdentities: Set<AgentSidebarSelectionIdentity>,
        workspaceID: UUID?
    ) -> AgentSidebarBulkActionOperation? {
        guard let operation = inFlightAction,
              operation.origin == .command,
              operation.workspaceID == workspaceID,
              operation.commandProgressPlacement == .row,
              !operation.commandRowProgressRetired,
              !operation.presentationTargets.isDisjoint(with: existingIdentities),
              operation.presentationTargets.isDisjoint(with: renderedIdentities)
        else { return nil }
        return operation
    }

    var archivedHeaderCommandProgressOperation: AgentSidebarBulkActionOperation? {
        guard let operation = inFlightAction,
              operation.origin == .command,
              operation.commandProgressPlacement == .archivedHeader
        else { return nil }
        return operation
    }

    mutating func handle(
        _ gesture: AgentSidebarSelectionGesture,
        identity: AgentSidebarSelectionIdentity,
        renderedOrder: [AgentSidebarSelectionIdentity],
        workspaceID: UUID
    ) -> AgentSidebarSelectionGestureDisposition {
        guard inFlightAction == nil, renderedOrder.contains(identity) else { return .ignored }
        if self.workspaceID != nil, self.workspaceID != workspaceID {
            self = AgentSidebarSelectionState(revision: revision &+ 1)
        }

        switch gesture {
        case .primary:
            guard !selectedIdentities.isEmpty else { return .activate }
            selectedIdentities = [identity]
            anchor = identity
        case .toggle:
            if selectedIdentities.remove(identity) == nil {
                selectedIdentities.insert(identity)
            }
            anchor = selectedIdentities.isEmpty ? nil : identity
        case .range:
            guard let anchor,
                  let anchorIndex = renderedOrder.firstIndex(of: anchor),
                  let identityIndex = renderedOrder.firstIndex(of: identity)
            else {
                self.workspaceID = workspaceID
                selectedIdentities = [identity]
                anchor = identity
                revision &+= 1
                return .selectionChanged
            }
            selectedIdentities = Set(renderedOrder[min(anchorIndex, identityIndex) ... max(anchorIndex, identityIndex)])
        }
        self.workspaceID = selectedIdentities.isEmpty ? nil : workspaceID
        revision &+= 1
        return .selectionChanged
    }

    mutating func selectAll(renderedOrder: [AgentSidebarSelectionIdentity], workspaceID: UUID) {
        guard inFlightAction == nil, !renderedOrder.isEmpty else { return }
        self.workspaceID = workspaceID
        selectedIdentities = Set(renderedOrder)
        anchor = renderedOrder.first
        revision &+= 1
    }

    mutating func clear() {
        guard inFlightAction == nil, !selectedIdentities.isEmpty || anchor != nil else { return }
        workspaceID = nil
        selectedIdentities.removeAll()
        anchor = nil
        revision &+= 1
    }

    mutating func reconcile(renderedOrder: [AgentSidebarSelectionIdentity], workspaceID: UUID?) {
        if self.workspaceID != nil, self.workspaceID != workspaceID {
            self = AgentSidebarSelectionState(revision: revision &+ 1)
            return
        }
        let rendered = Set(renderedOrder)
        let nextSelection = selectedIdentities.intersection(rendered)
        let nextAnchor = anchor.flatMap { rendered.contains($0) ? $0 : nil }
        guard nextSelection != selectedIdentities || nextAnchor != anchor else { return }
        selectedIdentities = nextSelection
        anchor = nextSelection.isEmpty ? nil : nextAnchor
        if nextSelection.isEmpty, inFlightAction == nil { self.workspaceID = nil }
        revision &+= 1
    }
}
