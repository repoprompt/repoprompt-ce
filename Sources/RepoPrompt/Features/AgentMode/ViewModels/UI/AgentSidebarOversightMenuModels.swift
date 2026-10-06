import Foundation
import RepoPromptDomainRuntime

/// Exact, target-centric relationship choices rendered by one active Agent sidebar row.
///
/// This is a presentation projection only. It carries no closures and is never placed in prompt
/// inventory, observation snapshots, passive status samples, or MCP responses.
struct AgentSidebarOversightMenuProps: Equatable {
    enum Relationship: Equatable {
        case available
        case linked(
            reference: DomainAgentSessionLinkReference,
            observerCurrentlyEligible: Bool
        )
    }

    struct ObserverOption: Identifiable, Equatable {
        let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let observerSessionID: UUID
        let displayName: String
        let providerDisplayName: String?
        let menuLabel: String
        let fullIdentityDescription: String
        let relationship: Relationship

        var id: DomainAgentSessionLinkEndpointIdentity {
            observerEndpoint
        }
    }

    let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    let targetSessionID: UUID
    let targetDisplayName: String
    let observerOptions: [ObserverOption]
    var createdByLabel: String?

    var linkedObservers: [ObserverOption] {
        observerOptions.filter {
            if case .linked = $0.relationship { return true }
            return false
        }
    }

    var availableObservers: [ObserverOption] {
        observerOptions.filter { $0.relationship == .available }
    }

    var isEmpty: Bool {
        observerOptions.isEmpty
    }
}

/// Result of one exact sidebar relationship action.
enum AgentSidebarOversightActionOutcome: Equatable {
    case changed
    case alreadyInRequestedState
    case failed(message: String)

    var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

/// Copy for removing one target-scoped oversight relationship from the sidebar menu.
enum AgentSidebarOversightMenuCopy {
    static func stopTitle(observerMenuLabel: String) -> String {
        "Stop oversight by “\(observerMenuLabel)”"
    }

    static func stopAccessibilityLabel(
        observerMenuLabel: String,
        targetDisplayName: String
    ) -> String {
        "Stop oversight of \(targetDisplayName) by “\(observerMenuLabel)”"
    }
}

/// Exact row-local busy identity. Unrelated relationships may mutate concurrently.
enum AgentSidebarOversightActionKey: Hashable {
    case add(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    )
    case unlink(
        observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        reference: DomainAgentSessionLinkReference
    )
}

/// Pure construction of one target's menu from a single authority projection and live-candidate
/// snapshot.
///
/// Linked relationships are authority-owned and therefore survive a missing or newly-ineligible
/// observer candidate. Available options intersect exact authority-owned outbound membership with a
/// live-candidate presentation snapshot; the exact Add operation revalidates them before mutating.
enum AgentSidebarOversightMenuProjection {
    fileprivate struct Seed {
        let observerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let observerSessionID: UUID
        let displayName: String
        let providerDisplayName: String?
        let locationLabel: String?
        let relationship: AgentSidebarOversightMenuProps.Relationship

        let baseMenuLabel: String
        let fullIdentityDescription: String
        let foldedName: String
        let sessionSortKey: String
        let workspaceSortKey: String
        let tabSortKey: String
        let bindingSortKey: String

        init(
            observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
            observerSessionID: UUID,
            displayName: String,
            providerDisplayName: String?,
            locationLabel: String?,
            relationship: AgentSidebarOversightMenuProps.Relationship
        ) {
            self.observerEndpoint = observerEndpoint
            self.observerSessionID = observerSessionID
            self.displayName = displayName
            self.providerDisplayName = providerDisplayName
            self.locationLabel = locationLabel
            self.relationship = relationship
            let location = locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            baseMenuLabel = location.isEmpty ? displayName : "\(location): \(displayName)"
            foldedName = folded(displayName)
            sessionSortKey = observerSessionID.uuidString
            workspaceSortKey = observerEndpoint.workspaceID.uuidString
            tabSortKey = observerEndpoint.tabID.uuidString
            bindingSortKey = observerEndpoint.persistentBindingGeneration?.uuidString ?? ""
            fullIdentityDescription = "session \(sessionSortKey); window \(observerEndpoint.windowID); "
                + "workspace \(workspaceSortKey); tab \(tabSortKey); "
                + "binding \(bindingSortKey.isEmpty ? "unresolved" : bindingSortKey); "
                + "transition \(observerEndpoint.bindingTransitionGeneration)"
        }
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// Immutable preparation for one candidate snapshot, shared by every row in a refresh pass.
    struct CandidateIndex {
        let byEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkEndpointCandidate]
        fileprivate let labelsAreUnique: Bool
        fileprivate let orderedObservers: [Seed]
        fileprivate let observerEligibleEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>

        init(_ candidates: [AgentSessionLinkEndpointCandidate]) {
            // Choose representatives before sorting: descriptive lookups remain live first-match.
            byEndpoint = Dictionary(candidates.map { ($0.domainEndpoint, $0) }, uniquingKeysWith: { first, _ in first })
            orderedObservers = byEndpoint.values.map { candidate in
                Seed(
                    observerEndpoint: candidate.domainEndpoint,
                    observerSessionID: candidate.sessionID,
                    displayName: candidate.resolvedDisplayName,
                    providerDisplayName: normalizedProvider(candidate.providerDisplayName),
                    locationLabel: candidate.locationLabel,
                    relationship: .available
                )
            }.sorted(by: orderedBefore)
            labelsAreUnique = Set(orderedObservers.map(\.baseMenuLabel)).count == orderedObservers.count
            observerEligibleEndpoints = Set(byEndpoint.values.filter {
                AgentSessionLinkEndpointEligibility.addDisabledReason(
                    $0.eligibilityInput, roleAllowsOutboundMonitoring: $0.roleAllowsOutboundMonitoring
                ) == nil
            }.map(\.domainEndpoint))
        }
    }

    static func make(
        target: AgentSessionLinkEndpointCandidate,
        inputs: DomainAgentSessionLinkEndpointProjectionInputs,
        candidates: [AgentSessionLinkEndpointCandidate],
        createdByLabel: String? = nil
    ) -> AgentSidebarOversightMenuProps? {
        make(
            target: target,
            inputs: inputs,
            candidateIndex: CandidateIndex(candidates),
            createdByLabel: createdByLabel
        )
    }

    static func make(
        target: AgentSessionLinkEndpointCandidate,
        inputs: DomainAgentSessionLinkEndpointProjectionInputs,
        candidateIndex: CandidateIndex,
        createdByLabel: String? = nil
    ) -> AgentSidebarOversightMenuProps? {
        guard AgentSessionLinkEndpointEligibility.targetResolveFailure(for: target) == nil else {
            return nil
        }

        let candidatesByEndpoint = candidateIndex.byEndpoint
        var linkedEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
        var linked: [Seed] = []
        linked.reserveCapacity(inputs.inbound.items.count)

        for item in inputs.inbound.items {
            guard let observerEndpoint = inputs.inboundObserverEndpoints[item.linkID] else {
                assertionFailure("Active inbound oversight link is missing its exact observer endpoint.")
                continue
            }
            guard linkedEndpoints.insert(observerEndpoint).inserted else {
                assertionFailure("Target projection contains duplicate links from one exact observer endpoint.")
                continue
            }
            if observerEndpoint.sessionID != item.observerSessionID {
                assertionFailure("Inbound oversight inventory and exact observer endpoint disagree.")
            }
            let observer = candidatesByEndpoint[observerEndpoint]
            let observerCurrentlyEligible = observer.map {
                AgentSessionLinkEndpointEligibility.addDisabledReason(
                    $0.eligibilityInput,
                    roleAllowsOutboundMonitoring: $0.roleAllowsOutboundMonitoring
                ) == nil
            } ?? false
            linked.append(Seed(
                observerEndpoint: observerEndpoint,
                observerSessionID: observerEndpoint.sessionID,
                displayName: observer?.resolvedDisplayName
                    ?? AgentMonitorSessionIDFormatter.short(observerEndpoint.sessionID),
                providerDisplayName: normalizedProvider(observer?.providerDisplayName),
                locationLabel: observer?.locationLabel,
                relationship: .linked(
                    reference: DomainAgentSessionLinkReference(
                        linkID: item.linkID,
                        generation: item.generation
                    ),
                    observerCurrentlyEligible: observerCurrentlyEligible
                )
            ))
        }

        var available: [Seed] = []
        for observer in candidateIndex.orderedObservers {
            let observerEndpoint = observer.observerEndpoint
            guard observer.observerSessionID != target.sessionID,
                  !linkedEndpoints.contains(observerEndpoint),
                  inputs.activeOutboundObserverEndpoints.contains(observerEndpoint),
                  candidateIndex.observerEligibleEndpoints.contains(observerEndpoint)
            else {
                continue
            }
            available.append(observer)
        }

        let seeds = linked.sorted(by: orderedBefore) + available
        let labels = collisionSafeLabels(for: seeds, linked: linked, candidateIndex: candidateIndex)
        let options = seeds.map { seed in
            AgentSidebarOversightMenuProps.ObserverOption(
                observerEndpoint: seed.observerEndpoint,
                observerSessionID: seed.observerSessionID,
                displayName: seed.displayName,
                providerDisplayName: seed.providerDisplayName,
                menuLabel: labels[seed.observerEndpoint] ?? seed.baseMenuLabel,
                fullIdentityDescription: seed.fullIdentityDescription,
                relationship: seed.relationship
            )
        }
        return AgentSidebarOversightMenuProps(
            targetEndpoint: target.domainEndpoint,
            targetSessionID: target.sessionID,
            targetDisplayName: target.resolvedDisplayName,
            observerOptions: options,
            createdByLabel: createdByLabel
        )
    }

    private static func normalizedProvider(_ provider: String?) -> String? {
        guard let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty
        else {
            return nil
        }
        return provider
    }

    private static func orderedBefore(_ lhs: Seed, _ rhs: Seed) -> Bool {
        let lhsName = lhs.foldedName
        let rhsName = rhs.foldedName
        if lhsName != rhsName { return lhsName < rhsName }

        let lhsSession = lhs.sessionSortKey
        let rhsSession = rhs.sessionSortKey
        if lhsSession != rhsSession { return lhsSession < rhsSession }
        if lhs.observerEndpoint.windowID != rhs.observerEndpoint.windowID {
            return lhs.observerEndpoint.windowID < rhs.observerEndpoint.windowID
        }

        let lhsWorkspace = lhs.workspaceSortKey
        let rhsWorkspace = rhs.workspaceSortKey
        if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }

        let lhsTab = lhs.tabSortKey
        let rhsTab = rhs.tabSortKey
        if lhsTab != rhsTab { return lhsTab < rhsTab }

        let lhsBinding = lhs.bindingSortKey
        let rhsBinding = rhs.bindingSortKey
        if lhsBinding != rhsBinding { return lhsBinding < rhsBinding }
        return lhs.observerEndpoint.bindingTransitionGeneration
            < rhs.observerEndpoint.bindingTransitionGeneration
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: foldingLocale
        )
    }

    /// Widen only colliding labels, one exact component at a time, while keeping unique names clean.
    private static func collisionSafeLabels(
        for seeds: [Seed],
        linked: [Seed],
        candidateIndex: CandidateIndex
    ) -> [DomainAgentSessionLinkEndpointIdentity: String] {
        // Every subset of unique snapshot labels is unique. Linked fallback labels must first prove
        // they are the same snapshot labels; missing peers and changed fallback locations use the
        // ordinary row-specific collision widening below, never global disambiguation.
        if candidateIndex.labelsAreUnique, linked.allSatisfy({ seed in
            guard let candidate = candidateIndex.byEndpoint[seed.observerEndpoint] else { return false }
            return seed.displayName == candidate.resolvedDisplayName && seed.locationLabel == candidate.locationLabel
        }) {
            return [:]
        }
        var labels = Dictionary(
            uniqueKeysWithValues: seeds.map { ($0.observerEndpoint, $0.baseMenuLabel) }
        )
        widenCollisions(in: &labels, seeds: seeds) { seed in
            "\(seed.baseMenuLabel) (\(shortUUID(seed.observerSessionID)))"
        }
        widenCollisions(in: &labels, seeds: seeds) { seed in
            "\(seed.baseMenuLabel) (\(shortUUID(seed.observerSessionID)), "
                + "window \(seed.observerEndpoint.windowID))"
        }
        widenCollisions(in: &labels, seeds: seeds) { seed in
            "\(seed.baseMenuLabel) (\(shortUUID(seed.observerSessionID)), "
                + "window \(seed.observerEndpoint.windowID), "
                + "tab \(shortUUID(seed.observerEndpoint.tabID)))"
        }
        widenCollisions(in: &labels, seeds: seeds) { seed in
            "\(seed.baseMenuLabel) (\(seed.fullIdentityDescription))"
        }
        return labels
    }

    private static func widenCollisions(
        in labels: inout [DomainAgentSessionLinkEndpointIdentity: String],
        seeds: [Seed],
        replacement: (Seed) -> String
    ) {
        let counts = Dictionary(grouping: labels.values, by: { $0 }).mapValues(\.count)
        for seed in seeds {
            guard let label = labels[seed.observerEndpoint], counts[label, default: 0] > 1 else {
                continue
            }
            labels[seed.observerEndpoint] = replacement(seed)
        }
    }

    private static func shortUUID(_ id: UUID) -> String {
        let raw = id.uuidString
        return "\(raw.prefix(4))…\(raw.suffix(4))"
    }
}
