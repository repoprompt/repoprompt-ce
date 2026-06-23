import Foundation
import RepoPromptCore

/// Immutable identity for resolving one exact app adapter mapping.
///
/// Tickets deliberately contain no object references. A ticket remains useful for diagnosing
/// or rejecting stale work after its adapter is gone, but can never discover a replacement.
struct MCPRuntimeAdapterTicket: Hashable, @unchecked Sendable {
    let windowID: Int
    let runtimeID: WorkspaceRuntimeID
    let sessionID: WorkspaceSessionID
    let adapterID: UUID
    let mappingGeneration: UInt64
    let authoritativeSnapshotSequence: UInt64
}

enum MCPRuntimeRoutingAvailability: Equatable {
    case created
    case hydrating
    case awaitingActivation
    case active
    case switching
    case failed(String)
    case closing
    case closed

    init(_ availability: WorkspaceSessionAvailability) {
        switch availability {
        case .created: self = .created
        case .hydrating: self = .hydrating
        case .awaitingActivation: self = .awaitingActivation
        case .active: self = .active
        case .switching: self = .switching
        case let .failed(message): self = .failed(message)
        case .closing: self = .closing
        case .closed: self = .closed
        }
    }
}

struct MCPRuntimeComposeTabRoutingSnapshot: Equatable {
    let id: UUID
    let name: String
}

struct MCPRuntimeWorkspaceRoutingSnapshot: Equatable {
    let id: UUID
    let name: String
    let isSystemWorkspace: Bool
    let isHiddenInMenus: Bool
    /// Ordered logical roots used by the compatibility binding algorithms.
    let orderedRootPaths: [String]
    let activeComposeTabID: UUID?
    let composeTabs: [MCPRuntimeComposeTabRoutingSnapshot]
}

/// Immutable, app-safe projection of a workspace-session snapshot.
///
/// This type contains no mutable models, worktree projections, or UI references. The configured
/// workspace roots preserve compatibility routing while validated physical worktree locations
/// remain in the admitted Core query capability.
struct MCPRuntimeRoutingSnapshot: Equatable, @unchecked Sendable {
    let windowID: Int
    let runtimeID: WorkspaceRuntimeID
    let sessionID: WorkspaceSessionID
    let adapterID: UUID
    let mappingGeneration: UInt64
    let authoritativeSnapshotSequence: UInt64
    let stateGeneration: UInt64
    let availability: MCPRuntimeRoutingAvailability
    let activeWorkspaceID: UUID?
    let workspaces: [MCPRuntimeWorkspaceRoutingSnapshot]

    var ticket: MCPRuntimeAdapterTicket {
        MCPRuntimeAdapterTicket(
            windowID: windowID,
            runtimeID: runtimeID,
            sessionID: sessionID,
            adapterID: adapterID,
            mappingGeneration: mappingGeneration,
            authoritativeSnapshotSequence: authoritativeSnapshotSequence
        )
    }

    init?(
        windowID: Int,
        runtimeID: WorkspaceRuntimeID,
        sessionID: WorkspaceSessionID,
        adapterID: UUID,
        mappingGeneration: UInt64,
        authoritativeSnapshot: WorkspaceSessionSnapshot
    ) {
        guard authoritativeSnapshot.sessionID == sessionID else { return nil }
        self.windowID = windowID
        self.runtimeID = runtimeID
        self.sessionID = sessionID
        self.adapterID = adapterID
        self.mappingGeneration = mappingGeneration
        authoritativeSnapshotSequence = authoritativeSnapshot.snapshotSequence
        stateGeneration = authoritativeSnapshot.stateGeneration
        availability = MCPRuntimeRoutingAvailability(authoritativeSnapshot.availability)
        activeWorkspaceID = authoritativeSnapshot.activeWorkspaceID
        workspaces = authoritativeSnapshot.workspaces.map { workspace in
            MCPRuntimeWorkspaceRoutingSnapshot(
                id: workspace.id,
                name: workspace.name,
                isSystemWorkspace: workspace.isSystemWorkspace,
                isHiddenInMenus: workspace.isHiddenInMenus,
                orderedRootPaths: workspace.repoPaths,
                activeComposeTabID: workspace.activeComposeTabID,
                composeTabs: workspace.composeTabs.map {
                    MCPRuntimeComposeTabRoutingSnapshot(id: $0.id, name: $0.name)
                }
            )
        }
    }
}

/// A value snapshot of all mappings currently available for new MCP resolution.
struct MCPRuntimeRoutingTableSnapshot: Equatable, @unchecked Sendable {
    let publicationSequence: UInt64
    let mappings: [MCPRuntimeRoutingSnapshot]

    func mapping(windowID: Int) -> MCPRuntimeRoutingSnapshot? {
        mappings.first { $0.windowID == windowID }
    }
}

enum MCPRuntimeUIAdapterError: Error, Equatable {
    case windowStateUnavailable
    case serverViewModelUnavailable
}

/// App-only UI bridge. `WindowState` owns this wrapper strongly; all referenced UI state is weak.
@MainActor
final class MCPWindowRuntimeAdapter {
    let adapterID: UUID
    private(set) weak var windowState: WindowState?
    private(set) weak var serverViewModel: MCPServerViewModel?
    private var deinitHandler: (@Sendable (UUID) -> Void)?

    init(
        adapterID: UUID = UUID(),
        windowState: WindowState?,
        serverViewModel: MCPServerViewModel?
    ) {
        self.adapterID = adapterID
        self.windowState = windowState
        self.serverViewModel = serverViewModel
    }

    func requireWindowState() throws -> WindowState {
        guard let windowState else { throw MCPRuntimeUIAdapterError.windowStateUnavailable }
        return windowState
    }

    func requireServerViewModel() throws -> MCPServerViewModel {
        guard let serverViewModel else { throw MCPRuntimeUIAdapterError.serverViewModelUnavailable }
        return serverViewModel
    }

    func attach(windowState: WindowState) {
        precondition(self.windowState == nil || self.windowState === windowState)
        self.windowState = windowState
    }

    fileprivate func installDeinitHandler(_ handler: @escaping @Sendable (UUID) -> Void) {
        deinitHandler = handler
    }

    deinit {
        deinitHandler?(adapterID)
    }
}

enum MCPRuntimeAdapterPublicationState: Equatable {
    case staged
    case active
    case closing
    case removed
}

enum MCPRuntimeAdapterStageResult: Equatable {
    case staged(MCPRuntimeAdapterTicket)
    case duplicateRuntimeID
    case windowOccupied
    case predecessorNotDraining
    case sessionMismatch
}

enum MCPRuntimeAdapterActivationResult: Equatable {
    case activated(MCPRuntimeAdapterTicket)
    case alreadyActive(MCPRuntimeAdapterTicket)
    case notFound
    case staleTicket
    case adapterUnavailable
    case invalidState(MCPRuntimeAdapterPublicationState)
}

enum MCPRuntimeAdapterSnapshotUpdateResult: Equatable {
    case updated(MCPRuntimeAdapterTicket)
    case ignoredStaleOrDuplicate
    case notFound
    case identityMismatch
    case invalidState(MCPRuntimeAdapterPublicationState)
}

enum MCPRuntimeAdapterClosingResult: Equatable {
    case closing
    case alreadyClosing
    case removed
    case notFound
    case staleTicket
}

/// Main-actor compatibility mapping between public window IDs and Core runtime identities.
///
/// Entries are keyed by runtime so a closing predecessor can coexist with a staged replacement
/// under the same public window ID. Only the current active entry appears in routing snapshots.
@MainActor
final class MCPAppRuntimeAdapterRegistry {
    private final class Entry {
        let windowID: Int
        let runtimeID: WorkspaceRuntimeID
        let sessionID: WorkspaceSessionID
        let adapterID: UUID
        let mappingGeneration: UInt64
        weak var adapter: MCPWindowRuntimeAdapter?
        var routingSnapshot: MCPRuntimeRoutingSnapshot
        var state: MCPRuntimeAdapterPublicationState

        init(
            windowID: Int,
            runtimeID: WorkspaceRuntimeID,
            sessionID: WorkspaceSessionID,
            adapter: MCPWindowRuntimeAdapter,
            mappingGeneration: UInt64,
            routingSnapshot: MCPRuntimeRoutingSnapshot
        ) {
            self.windowID = windowID
            self.runtimeID = runtimeID
            self.sessionID = sessionID
            adapterID = adapter.adapterID
            self.adapter = adapter
            self.mappingGeneration = mappingGeneration
            self.routingSnapshot = routingSnapshot
            state = .staged
        }

        var ticket: MCPRuntimeAdapterTicket {
            routingSnapshot.ticket
        }
    }

    private var entriesByRuntimeID: [WorkspaceRuntimeID: Entry] = [:]
    private var currentRuntimeByWindowID: [Int: WorkspaceRuntimeID] = [:]
    private var closingRuntimeByWindowID: [Int: WorkspaceRuntimeID] = [:]
    private var drainingRuntimeIDs: Set<WorkspaceRuntimeID> = []
    private var nextMappingGeneration: UInt64 = 0
    private var routingPublicationSequence: UInt64 = 0
    private(set) var latestRoutingTableSnapshot = MCPRuntimeRoutingTableSnapshot(
        publicationSequence: 0,
        mappings: []
    )

    private let runtimeBeganClosing: @MainActor (WorkspaceRuntimeID) -> Void

    init(runtimeBeganClosing: @escaping @MainActor (WorkspaceRuntimeID) -> Void = { _ in }) {
        self.runtimeBeganClosing = runtimeBeganClosing
    }

    @discardableResult
    func stage(
        windowID: Int,
        runtimeID: WorkspaceRuntimeID,
        sessionID: WorkspaceSessionID,
        authoritativeSnapshot: WorkspaceSessionSnapshot,
        adapter: MCPWindowRuntimeAdapter
    ) -> MCPRuntimeAdapterStageResult {
        guard entriesByRuntimeID[runtimeID] == nil else { return .duplicateRuntimeID }
        guard authoritativeSnapshot.sessionID == sessionID else { return .sessionMismatch }
        if let currentRuntimeID = currentRuntimeByWindowID[windowID],
           let current = entriesByRuntimeID[currentRuntimeID],
           current.state == .staged || current.state == .active
        {
            return .windowOccupied
        }
        if let predecessorRuntimeID = closingRuntimeByWindowID[windowID] {
            guard drainingRuntimeIDs.contains(predecessorRuntimeID) else {
                return .predecessorNotDraining
            }
            closingRuntimeByWindowID.removeValue(forKey: windowID)
        }

        nextMappingGeneration &+= 1
        guard let routingSnapshot = MCPRuntimeRoutingSnapshot(
            windowID: windowID,
            runtimeID: runtimeID,
            sessionID: sessionID,
            adapterID: adapter.adapterID,
            mappingGeneration: nextMappingGeneration,
            authoritativeSnapshot: authoritativeSnapshot
        ) else {
            return .sessionMismatch
        }

        let entry = Entry(
            windowID: windowID,
            runtimeID: runtimeID,
            sessionID: sessionID,
            adapter: adapter,
            mappingGeneration: nextMappingGeneration,
            routingSnapshot: routingSnapshot
        )
        entriesByRuntimeID[runtimeID] = entry
        currentRuntimeByWindowID[windowID] = runtimeID
        adapter.installDeinitHandler { [weak self] adapterID in
            Task { @MainActor [weak self] in
                self?.adapterDidDeinitialize(runtimeID: runtimeID, adapterID: adapterID)
            }
        }
        return .staged(entry.ticket)
    }

    @discardableResult
    func activate(ticket: MCPRuntimeAdapterTicket) -> MCPRuntimeAdapterActivationResult {
        guard let entry = entriesByRuntimeID[ticket.runtimeID] else { return .notFound }
        guard entry.ticket == ticket else { return .staleTicket }
        guard entry.adapter != nil else {
            markClosingAfterAdapterLoss(entry)
            return .adapterUnavailable
        }
        switch entry.state {
        case .staged:
            entry.state = .active
            publishRoutingTable()
            return .activated(entry.ticket)
        case .active:
            return .alreadyActive(entry.ticket)
        case .closing, .removed:
            return .invalidState(entry.state)
        }
    }

    @discardableResult
    func updateSnapshot(
        runtimeID: WorkspaceRuntimeID,
        sessionID: WorkspaceSessionID,
        authoritativeSnapshot: WorkspaceSessionSnapshot
    ) -> MCPRuntimeAdapterSnapshotUpdateResult {
        guard let entry = entriesByRuntimeID[runtimeID] else { return .notFound }
        guard entry.sessionID == sessionID, authoritativeSnapshot.sessionID == sessionID else {
            return .identityMismatch
        }
        guard entry.state == .staged || entry.state == .active else {
            return .invalidState(entry.state)
        }
        guard authoritativeSnapshot.snapshotSequence > entry.routingSnapshot.authoritativeSnapshotSequence else {
            return .ignoredStaleOrDuplicate
        }
        guard let routingSnapshot = MCPRuntimeRoutingSnapshot(
            windowID: entry.windowID,
            runtimeID: entry.runtimeID,
            sessionID: entry.sessionID,
            adapterID: entry.adapterID,
            mappingGeneration: entry.mappingGeneration,
            authoritativeSnapshot: authoritativeSnapshot
        ) else {
            return .identityMismatch
        }
        entry.routingSnapshot = routingSnapshot
        if entry.state == .active { publishRoutingTable() }
        return .updated(entry.ticket)
    }

    /// Returns the latest immutable active mapping for a compatibility window ID.
    func routingSnapshot(windowID: Int) -> MCPRuntimeRoutingSnapshot? {
        guard let runtimeID = currentRuntimeByWindowID[windowID],
              let entry = entriesByRuntimeID[runtimeID],
              entry.state == .active
        else { return nil }
        guard entry.adapter != nil else {
            markClosingAfterAdapterLoss(entry)
            return nil
        }
        return entry.routingSnapshot
    }

    /// Resolves only the exact adapter named by `ticket`; replacement mappings are never used.
    func adapter(for ticket: MCPRuntimeAdapterTicket) -> MCPWindowRuntimeAdapter? {
        guard let entry = entriesByRuntimeID[ticket.runtimeID],
              entry.state == .active,
              entry.ticket == ticket,
              currentRuntimeByWindowID[ticket.windowID] == ticket.runtimeID
        else { return nil }
        guard let adapter = entry.adapter else {
            markClosingAfterAdapterLoss(entry)
            return nil
        }
        return adapter
    }

    func captureRuntimeFileToolSnapshot(
        ticket: MCPRuntimeAdapterTicket
    ) async -> MCPRuntimeFileToolSnapshot? {
        guard let adapter = adapter(for: ticket),
              let serverViewModel = adapter.serverViewModel
        else { return nil }
        let promptViewModel = adapter.windowState?.promptManager ?? serverViewModel.promptVM
        let metadata = await serverViewModel.captureRequestMetadata()
        let lookupContext = await serverViewModel.resolveFileToolLookupContext(from: metadata)
        return MCPRuntimeFileToolSnapshot(
            adapterTicket: ticket,
            runtimeID: ticket.runtimeID,
            sessionID: ticket.sessionID,
            lookupContext: lookupContext,
            filePathDisplay: promptViewModel.filePathDisplayOption,
            codeMapsEnabled: !promptViewModel.codeMapsGloballyDisabled
        )
    }

    @discardableResult
    func beginClosing(runtimeID: WorkspaceRuntimeID) -> MCPRuntimeAdapterClosingResult {
        guard let entry = entriesByRuntimeID[runtimeID] else { return .notFound }
        return beginClosing(entry)
    }

    func confirmRuntimeDraining(runtimeID: WorkspaceRuntimeID) {
        guard entriesByRuntimeID[runtimeID]?.state == .closing else { return }
        drainingRuntimeIDs.insert(runtimeID)
    }

    @discardableResult
    func beginClosing(ticket: MCPRuntimeAdapterTicket) -> MCPRuntimeAdapterClosingResult {
        guard let entry = entriesByRuntimeID[ticket.runtimeID] else { return .notFound }
        guard entry.ticket == ticket else { return .staleTicket }
        return beginClosing(entry)
    }

    @discardableResult
    func markRemoved(runtimeID: WorkspaceRuntimeID) -> Bool {
        guard let entry = entriesByRuntimeID[runtimeID] else { return false }
        if currentRuntimeByWindowID[entry.windowID] == runtimeID {
            currentRuntimeByWindowID.removeValue(forKey: entry.windowID)
        }
        if closingRuntimeByWindowID[entry.windowID] == runtimeID {
            closingRuntimeByWindowID.removeValue(forKey: entry.windowID)
        }
        drainingRuntimeIDs.remove(runtimeID)
        entry.state = .removed
        entry.adapter = nil
        publishRoutingTable()
        return true
    }

    @discardableResult
    func purgeRemoved(runtimeID: WorkspaceRuntimeID) -> Bool {
        guard let entry = entriesByRuntimeID[runtimeID], entry.state == .removed else { return false }
        entriesByRuntimeID.removeValue(forKey: runtimeID)
        return true
    }

    func publicationState(runtimeID: WorkspaceRuntimeID) -> MCPRuntimeAdapterPublicationState? {
        entriesByRuntimeID[runtimeID]?.state
    }

    private func beginClosing(_ entry: Entry) -> MCPRuntimeAdapterClosingResult {
        switch entry.state {
        case .staged, .active:
            entry.state = .closing
            if currentRuntimeByWindowID[entry.windowID] == entry.runtimeID {
                currentRuntimeByWindowID.removeValue(forKey: entry.windowID)
            }
            closingRuntimeByWindowID[entry.windowID] = entry.runtimeID
            publishRoutingTable()
            runtimeBeganClosing(entry.runtimeID)
            return .closing
        case .closing:
            return .alreadyClosing
        case .removed:
            return .removed
        }
    }

    private func adapterDidDeinitialize(runtimeID: WorkspaceRuntimeID, adapterID: UUID) {
        guard let entry = entriesByRuntimeID[runtimeID],
              entry.adapterID == adapterID,
              entry.adapter == nil,
              entry.state == .staged || entry.state == .active
        else { return }
        markClosingAfterAdapterLoss(entry)
    }

    private func markClosingAfterAdapterLoss(_ entry: Entry) {
        guard entry.state == .staged || entry.state == .active else { return }
        _ = beginClosing(entry)
    }

    private func publishRoutingTable() {
        routingPublicationSequence &+= 1
        let mappings = currentRuntimeByWindowID.values.compactMap { runtimeID -> MCPRuntimeRoutingSnapshot? in
            guard let entry = entriesByRuntimeID[runtimeID],
                  entry.state == .active,
                  entry.adapter != nil
            else { return nil }
            return entry.routingSnapshot
        }.sorted {
            if $0.windowID != $1.windowID { return $0.windowID < $1.windowID }
            return $0.runtimeID.rawValue.uuidString < $1.runtimeID.rawValue.uuidString
        }
        latestRoutingTableSnapshot = MCPRuntimeRoutingTableSnapshot(
            publicationSequence: routingPublicationSequence,
            mappings: mappings
        )
    }
}
