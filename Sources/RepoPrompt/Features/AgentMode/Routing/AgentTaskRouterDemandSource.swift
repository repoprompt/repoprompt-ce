import Foundation
import RepoPromptSettingsCore

typealias AgentTaskRouterDemandSnapshot = RoutingSettingsSnapshot

extension RoutingSettingsSnapshot {
    var requiredBackendIDs: Set<DecisionServiceID> {
        var ids: Set<DecisionServiceID> = []
        if routerEnabled, let raw = selectedBackendRawValue,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            ids.insert(.init(rawValue: raw))
        }
        if autoEffortEnabled {
            let raw = autoEffortBackendRawValue ?? DecisionServiceID.jev.rawValue
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ids.insert(.init(rawValue: raw))
            }
        }
        return ids
    }
}

@MainActor
protocol AgentTaskRouterDemandSource: Sendable {
    func routerDemandSnapshot() -> AgentTaskRouterDemandSnapshot
    func routerDemandUpdates() -> AsyncStream<AgentTaskRouterDemandSnapshot>
}

extension GlobalSettingsStore: AgentTaskRouterDemandSource {
    func routerDemandSnapshot() -> AgentTaskRouterDemandSnapshot {
        routingSettingsSnapshot()
    }

    func routerDemandUpdates() -> AsyncStream<AgentTaskRouterDemandSnapshot> {
        routingSettingsUpdates()
    }
}
