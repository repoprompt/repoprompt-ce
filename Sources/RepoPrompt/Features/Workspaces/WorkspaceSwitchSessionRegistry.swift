import Foundation

@MainActor
final class WorkspaceDeletionCancellationToken {
    let workspaceID: UUID
    private(set) var isCancelled = false

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
    }

    var isActive: Bool {
        !isCancelled
    }

    func cancel() {
        isCancelled = true
    }
}

@MainActor
protocol WorkspaceSwitchSessionProvider: AnyObject {
    func switchSessionItems() -> [WorkspaceSwitchSessionItem]
    func cancelSwitchSessions() async
    func cancelSwitchSessions(for deletionToken: WorkspaceDeletionCancellationToken?) async
}

extension WorkspaceSwitchSessionProvider {
    func cancelSwitchSessions(for deletionToken: WorkspaceDeletionCancellationToken?) async {
        guard deletionToken?.isActive ?? true else { return }
        await cancelSwitchSessions()
    }
}

@MainActor
final class WorkspaceSwitchSessionRegistry {
    private var providers: [any WorkspaceSwitchSessionProvider] = []

    func register(_ provider: any WorkspaceSwitchSessionProvider) {
        providers.append(provider)
    }

    func snapshot() -> WorkspaceSwitchSessionSnapshot {
        var aggregated: [String: WorkspaceSwitchSessionItem] = [:]

        for provider in providers {
            for item in provider.switchSessionItems() where item.count > 0 {
                if let existing = aggregated[item.id] {
                    aggregated[item.id] = WorkspaceSwitchSessionItem(
                        id: item.id,
                        count: existing.count + item.count,
                        singularLabel: existing.singularLabel,
                        pluralLabel: existing.pluralLabel
                    )
                } else {
                    aggregated[item.id] = item
                }
            }
        }

        let items = aggregated.values.sorted { $0.id < $1.id }
        return WorkspaceSwitchSessionSnapshot(items: items)
    }

    func cancelActiveSessions() async {
        await cancelActiveSessions(for: nil)
    }

    func cancelActiveSessions(for deletionToken: WorkspaceDeletionCancellationToken?) async {
        for provider in providers {
            guard deletionToken?.isActive ?? true else { return }
            await provider.cancelSwitchSessions(for: deletionToken)
        }
    }
}
