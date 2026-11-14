import Combine
import Foundation
import RepoPromptSettingsCore

/// A secondary presentation, never a session runtime or persistence owner. Selection and drafts
/// belong to this window; the source reads only the exact canonical session the user selected.
@MainActor
final class CommandCenterConversationModel: ObservableObject {
    struct Snapshot: Equatable {
        let windowID: Int
        let workspaceID: UUID
        let tabID: UUID
        let title: String
        let provider: String
        let runState: String
        let rows: [AgentChatItem]
        let hasEarlierRows: Bool
        let hasPendingInteraction: Bool
    }

    struct Source {
        let isCurrent: @MainActor () -> Bool
        let snapshot: @MainActor (Int) -> Snapshot?
        let changes: AnyPublisher<Void, Never>
    }

    enum LoadResult {
        case ready(Source)
        case unavailable(String)
    }

    private enum Destination: Hashable {
        case session(CommandCenterSessionRow.ID)
        case newSession(UUID?)
    }

    typealias Loader = @MainActor (CommandCenterSessionRow) async -> LoadResult
    @Published private(set) var selectedID: CommandCenterSessionRow.ID?
    @Published private(set) var projectID: UUID?
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false
    @Published var draft = ""
    private let load: Loader
    private let isEnabled: @MainActor () -> Bool
    private var destination = Destination.newSession(nil)
    private var drafts: [Destination: String] = [:]
    private var generation = UUID()
    private var source: Source?
    private var loading: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var timer: AnyCancellable?
    private(set) var rowLimit = 500

    init(
        isEnabled: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.experimentalCommandCenter() },
        load: @escaping Loader
    ) {
        self.isEnabled = isEnabled
        self.load = load
    }

    static func appModel() -> CommandCenterConversationModel {
        CommandCenterConversationModel(load: CommandCenterConversationHost.load)
    }

    func select(_ row: CommandCenterSessionRow) {
        guard isEnabled() else { return }
        detach()
        switchDraft(to: .session(row.id))
        selectedID = row.id
        projectID = row.workspaceID
        rowLimit = 500
        isLoading = true
        let expected = generation
        loading = Task { [weak self] in
            guard let self, isEnabled(), !Task.isCancelled else { return }
            let result = await load(row)
            guard generation == expected, isEnabled(), !Task.isCancelled else { return }
            isLoading = false
            loading = nil
            switch result {
            case let .unavailable(reason): message = reason
            case let .ready(source):
                install(source)
            }
        }
    }

    /// Adopt only the originating Send receipt's exact owner, without another owner lookup.
    func presentCreatedSession(_ id: CommandCenterSessionRow.ID, source: Source?) {
        guard isEnabled() else { return }
        detach()
        switchDraft(to: .session(id))
        selectedID = id
        projectID = id.workspaceID
        rowLimit = 500
        guard let source, source.isCurrent() else {
            message = "Open this session in its project to inspect its state. No replacement owner was adopted."
            return
        }
        install(source)
    }

    private func install(_ source: Source) {
        self.source = source
        observation = source.changes
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
        // Check the captured incarnation; never follow a replacement owner.
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func newSession(projectID: UUID? = nil) {
        guard isEnabled() else { return }
        detach()
        selectedID = nil
        self.projectID = projectID
        switchDraft(to: .newSession(projectID))
    }

    func chooseProject(_ id: UUID?) {
        guard selectedID == nil, isEnabled() else { return }
        projectID = id
        // Destination changes are explicit, but must not discard the text being composed.
        let text = draft
        switchDraft(to: .newSession(id))
        if !text.isEmpty { draft = text }
    }

    func showEarlier() {
        guard isEnabled(), rowLimit < 5000 else { return }
        rowLimit = min(5000, rowLimit + 500)
        refresh()
    }

    func refresh() {
        guard isEnabled() else { stop()
            return
        }
        guard let source else { return }
        guard source.isCurrent() else {
            detach()
            message = "This session's owner changed or closed. Select it again to reload, or open its workspace."
            return
        }
        // nil during the owner's terminal commit means retain the settled prior frame, not empty.
        if let next = source.snapshot(rowLimit), next != snapshot { snapshot = next }
    }

    func stop() {
        drafts[destination] = draft
        detach()
    }

    private func switchDraft(to next: Destination) {
        drafts[destination] = draft
        destination = next
        draft = drafts[next] ?? ""
    }

    private func detach() {
        generation = UUID()
        loading?.cancel()
        loading = nil
        observation = nil
        timer = nil
        source = nil
        snapshot = nil
        message = nil
        isLoading = false
    }
}

/// The owner's active-pane projection intentionally need not refresh for inactive tabs. Build this
/// window's display from retained canonical compacted turns plus the live mutable suffix instead;
/// never ask the owner to sync its active UI. Work is bounded to the requested tail (maximum 5,000).
enum CommandCenterConversationRows {
    static func build(
        transcript: AgentTranscript, working: [AgentChatItem], hiddenIDs: Set<UUID>, limit requested: Int
    ) -> (rows: [AgentChatItem], hasEarlier: Bool) {
        let limit = max(1, min(requested, 5000))
        let turns = transcript.turns.suffix(limit)
        let live = Array(working.suffix(limit))
        let liveIDs = Set(live.map(\.id))
        let retained = turns.filter { $0.retentionTier != .full }.flatMap {
            AgentTranscriptProjectionBuilder.rows(for: $0, archived: $0.retentionTier == .archived)
        }.filter { !liveIDs.contains($0.id) }
        let visible = (retained + live).filter { !hiddenIDs.contains($0.id) }
        return (Array(visible.suffix(limit)), transcript.turns.count > turns.count || working.count > live.count || visible.count > limit)
    }
}

/// Pure browser projection. No payload reads, owner lookup, hydration or window activation.
enum CommandCenterRecentSessions {
    struct Row: Identifiable, Equatable {
        let session: CommandCenterSessionRow
        let workspaceName: String
        let rootSummary: String
        var id: CommandCenterSessionRow.ID {
            session.id
        }
    }

    static func inventoryWorkspaceIDs(in snapshot: CommandCenterSnapshot) -> [UUID] {
        snapshot.workspaces.filter { !$0.unavailable && $0.savedCount == nil }.map(\.id)
    }

    static func rows(in snapshot: CommandCenterSnapshot, matching search: String) -> [Row] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.workspaces.flatMap { workspace in
            workspace.sessions.map { Row(session: $0, workspaceName: workspace.name, rootSummary: workspace.roots.joined(separator: " · ")) }
        }.filter {
            query.isEmpty || [$0.session.name, $0.workspaceName, $0.rootSummary]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted {
            if $0.session.activityDate != $1.session.activityDate { return $0.session.activityDate > $1.session.activityDate }
            if $0.workspaceName != $1.workspaceName { return $0.workspaceName.localizedStandardCompare($1.workspaceName) == .orderedAscending }
            if $0.session.workspaceID != $1.session.workspaceID { return $0.session.workspaceID.uuidString < $1.session.workspaceID.uuidString }
            return $0.session.sessionID.uuidString < $1.session.sessionID.uuidString
        }
    }
}
