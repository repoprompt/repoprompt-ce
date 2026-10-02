import Foundation

/// Exact two-direction relationship choices rendered by one active Agent sidebar row.
///
/// This is a presentation projection only. It carries no closures and is never placed in prompt
/// inventory, observation snapshots, passive status samples, or MCP responses.
///
/// The same value drives the Oversee-by mark menu, the hover affordance menu, and the
/// context-menu submenus. `observerOptions` is the inbound direction (who oversees this row);
/// `targetOptions` is the outbound direction (who this row oversees). Both carry linked
/// entries even when the peer is temporarily missing or ineligible, so the user can always
/// unlink a stale relationship.
package struct AgentSidebarOversightMenuProps: Equatable {
    package enum Relationship: Equatable {
        case available
        case linked(
            reference: DomainAgentSessionLinkReference,
            peerCurrentlyEligible: Bool
        )
    }

    /// One exact peer incarnation in either direction. `peerEndpoint` is the other end of the
    /// link: the observer for `observerOptions`, the target for `targetOptions`.
    package struct PeerOption: Identifiable, Equatable {
        package let peerEndpoint: DomainAgentSessionLinkEndpointIdentity
        package let peerSessionID: UUID
        package let displayName: String
        package let providerDisplayName: String?
        package let menuLabel: String
        package let fullIdentityDescription: String
        package let relationship: Relationship

        package init(
            peerEndpoint: DomainAgentSessionLinkEndpointIdentity,
            peerSessionID: UUID,
            displayName: String,
            providerDisplayName: String?,
            menuLabel: String,
            fullIdentityDescription: String,
            relationship: Relationship
        ) {
            self.peerEndpoint = peerEndpoint
            self.peerSessionID = peerSessionID
            self.displayName = displayName
            self.providerDisplayName = providerDisplayName
            self.menuLabel = menuLabel
            self.fullIdentityDescription = fullIdentityDescription
            self.relationship = relationship
        }

        package var id: DomainAgentSessionLinkEndpointIdentity {
            peerEndpoint
        }

        /// Compatibility spelling for the inbound direction (the peer is an observer).
        package var observerEndpoint: DomainAgentSessionLinkEndpointIdentity {
            peerEndpoint
        }

        /// Compatibility spelling for the outbound direction (the peer is a target).
        package var targetEndpoint: DomainAgentSessionLinkEndpointIdentity {
            peerEndpoint
        }
    }

    package init(
        targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        targetDisplayName: String,
        observerOptions: [PeerOption],
        createdByLabel: String? = nil,
        targetOptions: [PeerOption] = [],
        targetIneligibleReason: String? = nil,
        observerIneligibleReason: String? = nil,
        inboundObserverNames: [String] = [],
        inboundObserverSessionIDs: [UUID] = [],
        outboundTargetNames: [String] = [],
        creatorSessionID: UUID? = nil
    ) {
        self.targetEndpoint = targetEndpoint
        self.targetSessionID = targetSessionID
        self.targetDisplayName = targetDisplayName
        self.observerOptions = observerOptions
        self.targetOptions = targetOptions
        self.targetIneligibleReason = targetIneligibleReason
        self.observerIneligibleReason = observerIneligibleReason
        self.inboundObserverNames = inboundObserverNames
        self.inboundObserverSessionIDs = inboundObserverSessionIDs
        self.outboundTargetNames = outboundTargetNames
        self.createdByLabel = createdByLabel
        self.creatorSessionID = creatorSessionID
    }

    package typealias ObserverOption = PeerOption
    package typealias TargetOption = PeerOption

    /// The row's own exact endpoint. It is the *target* for `observerOptions` and the
    /// *observer* for `targetOptions`.
    package let targetEndpoint: DomainAgentSessionLinkEndpointIdentity
    package let targetSessionID: UUID
    package let targetDisplayName: String

    /// Oversee-by list: linked observers retained for unlinking, plus available candidates
    /// that already hold an outbound link (the existing-overseer rule, enforced again at Add).
    package let observerOptions: [PeerOption]
    /// Oversee list: linked targets retained for unlinking, plus eligible target candidates.
    /// Empty when the row cannot currently observe (see `observerIneligibleReason`).
    package let targetOptions: [PeerOption]

    /// Why the row cannot currently accept a new inbound link, or `nil` when it can.
    /// Rendered greyed-out in the Oversee-by menu instead of hiding the menu.
    package let targetIneligibleReason: String?
    /// Why the row cannot currently observe other sessions, or `nil` when it can. Includes
    /// the persistence blocker (it wins over lifecycle eligibility, matching `canAddReason`).
    package var observerIneligibleReason: String?

    /// Display names of the row's current overseers / targets, for the row mark tooltips.
    /// Derived from the authority inventories, so they remain correct even when the menu
    /// options are momentarily empty.
    package let inboundObserverNames: [String]
    package let inboundObserverSessionIDs: [UUID]
    package let outboundTargetNames: [String]

    package var createdByLabel: String?
    package var creatorSessionID: UUID?

    package var linkedObservers: [ObserverOption] {
        observerOptions.filter {
            if case .linked = $0.relationship { return true }
            return false
        }
    }

    package var availableObservers: [ObserverOption] {
        observerOptions.filter { $0.relationship == .available }
    }

    package var linkedTargets: [TargetOption] {
        targetOptions.filter {
            if case .linked = $0.relationship { return true }
            return false
        }
    }

    package var availableTargets: [TargetOption] {
        targetOptions.filter { $0.relationship == .available }
    }

    /// True when the row's creator still holds an inbound link — the Overseen-by section
    /// collapses to `Created and overseen by:` when it is the row's only overseer.
    package var creatorIsOverseer: Bool {
        creatorSessionID != nil
            && linkedObservers.contains { $0.peerSessionID == creatorSessionID }
    }

    package var creatorIsSoleOverseer: Bool {
        creatorIsOverseer && linkedObservers.count == 1
    }

    /// The separate `Created by:` section appears only when the creator is not (or no
    /// longer) an overseer — otherwise it is already in the Overseen-by list.
    package var showsCreatedBySection: Bool {
        createdByLabel != nil && creatorSessionID != nil && !creatorIsOverseer
    }

    package var hasInbound: Bool {
        !linkedObservers.isEmpty || !inboundObserverNames.isEmpty
    }

    package var isOverseer: Bool {
        !outboundTargetNames.isEmpty
    }

    package var isEmpty: Bool {
        observerOptions.isEmpty && targetOptions.isEmpty
    }

    /// Returns a copy whose observer-eligibility reason has been overlaid, used by
    /// `AgentMonitorPillProps.withPersistence` so the persistence blocker reaches the
    /// sidebar's inverse menu with the same precedence it has on the pill's Add control.
    package func withObserverIneligibleReason(_ reason: String?) -> AgentSidebarOversightMenuProps {
        guard reason != observerIneligibleReason else { return self }
        var copy = self
        copy.observerIneligibleReason = reason
        return copy
    }
}

/// User-facing failure text for the sidebar's pasted-ID resolvers. The resolvers speak plain
/// message strings (existing resolver and eligibility copy); this wrapper lets `Result` carry them.
package struct AgentOversightResolutionMessage: Error, Equatable {
    package let message: String

    package init(message: String) {
        self.message = message
    }
}

/// Resolution outcome for the sidebar Session-ID sheets. `.alreadyLinked` means the pair is
/// already linked in this direction: the sheet closes silently — no dialog, no message.
package enum AgentOversightSessionIDResolution: Equatable {
    case candidate(AgentSessionLinkEndpointCandidate)
    case alreadyLinked
}

/// Result of one exact sidebar relationship action.
package enum AgentSidebarOversightActionOutcome: Equatable {
    case changed
    case alreadyInRequestedState
    case failed(message: String)

    package var failureMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

/// Exact row-local busy identity. Unrelated relationships may mutate concurrently.
package enum AgentSidebarOversightActionKey: Hashable {
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

/// Pure construction of one row's two-direction menu data from a single authority projection
/// and live-candidate snapshot.
///
/// Linked relationships are authority-owned and therefore survive a missing or newly-ineligible
/// peer candidate. Available options intersect exact authority-owned membership with a
/// live-candidate presentation snapshot; the exact Add operation revalidates them before
/// mutating.
///
/// Ordering contract (approved 2026-09-30): in both directions the row's own workspace cohort
/// sorts first, then the rest by folded display name; the outbound list additionally keeps its
/// linked (ticked) entries first. Ineligible directions produce a greyed reason instead of a
/// hidden menu.
package enum AgentSidebarOversightMenuProjection {
    private struct Seed {
        let peerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let peerSessionID: UUID
        let displayName: String
        let providerDisplayName: String?
        let locationLabel: String?
        let relationship: AgentSidebarOversightMenuProps.Relationship

        var baseMenuLabel: String {
            guard let location = locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !location.isEmpty
            else {
                return displayName
            }
            return "\(location): \(displayName)"
        }

        var fullIdentityDescription: String {
            let binding = peerEndpoint.persistentBindingGeneration?.uuidString ?? "unresolved"
            return "session \(peerSessionID.uuidString); window \(peerEndpoint.windowID); "
                + "workspace \(peerEndpoint.workspaceID.uuidString); "
                + "tab \(peerEndpoint.tabID.uuidString); binding \(binding); "
                + "transition \(peerEndpoint.bindingTransitionGeneration)"
        }
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    package static func make(
        target: AgentSessionLinkEndpointCandidate,
        inputs: DomainAgentSessionLinkEndpointProjectionInputs,
        candidates: [AgentSessionLinkEndpointCandidate],
        createdByLabel: String? = nil,
        creatorSessionID: UUID? = nil
    ) -> AgentSidebarOversightMenuProps {
        let rowEndpoint = target.domainEndpoint
        let rowWorkspaceID = target.workspaceID

        // Both directions carry independent eligibility: a session can be a valid target while
        // unable to observe (for example MCP-controlled), and vice versa.
        let targetFailure = AgentSessionLinkEndpointEligibility.targetResolveFailure(for: target)
        let observerReason = AgentSessionLinkEndpointEligibility.addDisabledReason(
            target.eligibilityInput,
            roleAllowsOutboundMonitoring: target.roleAllowsOutboundMonitoring
        )

        let candidatesByEndpoint = Dictionary(
            candidates.map { ($0.domainEndpoint, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Display names resolve app-wide by session ID, like the candidate lists: a linked
        // peer whose live incarnation moved (rebind, generation rollover, another window)
        // still names itself, and the compact ID only shows for a truly unknown session.
        let candidatesBySessionID = Dictionary(
            candidates.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // MARK: Inbound (who oversees this row)

        var linkedObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
        var linkedObservers: [Seed] = []
        linkedObservers.reserveCapacity(inputs.inbound.items.count)

        for item in inputs.inbound.items {
            guard let observerEndpoint = inputs.inboundObserverEndpoints[item.linkID] else {
                assertionFailure("Active inbound oversight link is missing its exact observer endpoint.")
                continue
            }
            guard linkedObserverEndpoints.insert(observerEndpoint).inserted else {
                assertionFailure("Target projection contains duplicate links from one exact observer endpoint.")
                continue
            }
            if observerEndpoint.sessionID != item.observerSessionID {
                assertionFailure("Inbound oversight inventory and exact observer endpoint disagree.")
            }
            let observer = candidatesByEndpoint[observerEndpoint]
            let observerBySession = candidatesBySessionID[observerEndpoint.sessionID]
            let observerCurrentlyEligible = observer.map {
                AgentSessionLinkEndpointEligibility.addDisabledReason(
                    $0.eligibilityInput,
                    roleAllowsOutboundMonitoring: $0.roleAllowsOutboundMonitoring
                ) == nil
            } ?? false
            linkedObservers.append(Seed(
                peerEndpoint: observerEndpoint,
                peerSessionID: observerEndpoint.sessionID,
                displayName: observer?.resolvedDisplayName
                    ?? observerBySession?.resolvedDisplayName
                    ?? item.displayName
                    ?? AgentMonitorSessionIDFormatter.short(observerEndpoint.sessionID),
                providerDisplayName: normalizedProvider(
                    observer?.providerDisplayName ?? observerBySession?.providerDisplayName
                ),
                locationLabel: observer?.locationLabel ?? observerBySession?.locationLabel,
                relationship: .linked(
                    reference: DomainAgentSessionLinkReference(
                        linkID: item.linkID,
                        generation: item.generation
                    ),
                    peerCurrentlyEligible: observerCurrentlyEligible
                )
            ))
        }

        var availableObservers: [Seed] = []
        var availableObserverEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
        // New inbound links require an eligible target; a greyed reason replaces the list otherwise.
        if targetFailure == nil {
            for observer in candidates {
                let observerEndpoint = observer.domainEndpoint
                guard observer.sessionID != target.sessionID,
                      !linkedObserverEndpoints.contains(observerEndpoint),
                      availableObserverEndpoints.insert(observerEndpoint).inserted,
                      inputs.activeOutboundObserverEndpoints.contains(observerEndpoint),
                      AgentSessionLinkEndpointEligibility.addDisabledReason(
                          observer.eligibilityInput,
                          roleAllowsOutboundMonitoring: observer.roleAllowsOutboundMonitoring
                      ) == nil
                else {
                    continue
                }
                availableObservers.append(Seed(
                    peerEndpoint: observerEndpoint,
                    peerSessionID: observer.sessionID,
                    displayName: observer.resolvedDisplayName,
                    providerDisplayName: normalizedProvider(observer.providerDisplayName),
                    locationLabel: observer.locationLabel,
                    relationship: .available
                ))
            }
        }

        // MARK: Outbound (who this row oversees)

        var linkedTargetEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
        var linkedTargets: [Seed] = []
        linkedTargets.reserveCapacity(inputs.outbound.items.count)

        for item in inputs.outbound.items {
            guard let linkedTargetEndpoint = inputs.outboundTargetEndpoints[item.linkID] else {
                assertionFailure("Active outbound oversight link is missing its exact target endpoint.")
                continue
            }
            guard linkedTargetEndpoints.insert(linkedTargetEndpoint).inserted else {
                assertionFailure("Observer projection contains duplicate links to one exact target endpoint.")
                continue
            }
            if linkedTargetEndpoint.sessionID != item.targetSessionID {
                assertionFailure("Outbound oversight inventory and exact target endpoint disagree.")
            }
            let targetPeer = candidatesByEndpoint[linkedTargetEndpoint]
            let targetPeerBySession = candidatesBySessionID[linkedTargetEndpoint.sessionID]
            let targetCurrentlyEligible = targetPeer.map {
                AgentSessionLinkEndpointEligibility.targetResolveFailure(for: $0) == nil
            } ?? false
            linkedTargets.append(Seed(
                peerEndpoint: linkedTargetEndpoint,
                peerSessionID: linkedTargetEndpoint.sessionID,
                displayName: targetPeer?.resolvedDisplayName
                    ?? targetPeerBySession?.resolvedDisplayName
                    ?? item.displayName
                    ?? AgentMonitorSessionIDFormatter.short(linkedTargetEndpoint.sessionID),
                providerDisplayName: normalizedProvider(
                    targetPeer?.providerDisplayName ?? targetPeerBySession?.providerDisplayName
                ),
                locationLabel: targetPeer?.locationLabel ?? targetPeerBySession?.locationLabel,
                relationship: .linked(
                    reference: DomainAgentSessionLinkReference(
                        linkID: item.linkID,
                        generation: item.generation
                    ),
                    peerCurrentlyEligible: targetCurrentlyEligible
                )
            ))
        }

        var availableTargets: [Seed] = []
        var availableTargetEndpoints: Set<DomainAgentSessionLinkEndpointIdentity> = []
        // New outbound links require an eligible observer; a greyed reason replaces the list.
        if observerReason == nil {
            for peer in candidates {
                let peerEndpoint = peer.domainEndpoint
                guard peer.sessionID != target.sessionID,
                      !linkedTargetEndpoints.contains(peerEndpoint),
                      availableTargetEndpoints.insert(peerEndpoint).inserted,
                      AgentSessionLinkEndpointEligibility.targetResolveFailure(for: peer) == nil
                else {
                    continue
                }
                availableTargets.append(Seed(
                    peerEndpoint: peerEndpoint,
                    peerSessionID: peer.sessionID,
                    displayName: peer.resolvedDisplayName,
                    providerDisplayName: normalizedProvider(peer.providerDisplayName),
                    locationLabel: peer.locationLabel,
                    relationship: .available
                ))
            }
        }

        // MARK: Ordering and labels

        // Inbound: one flat checkmark list — own workspace first, then folded name.
        let observerSeeds = (linkedObservers + availableObservers)
            .sorted { orderedBefore($0, $1, currentWorkspaceID: rowWorkspaceID) }
        // Outbound: ticked first, then own-workspace-first and folded name within each group.
        let targetSeeds = linkedTargets.sorted {
            orderedBefore($0, $1, currentWorkspaceID: rowWorkspaceID)
        } + availableTargets.sorted {
            orderedBefore($0, $1, currentWorkspaceID: rowWorkspaceID)
        }

        let observerLabels = collisionSafeLabels(for: observerSeeds)
        let targetLabels = collisionSafeLabels(for: targetSeeds)

        let observerOptions = observerSeeds.map { seed in
            AgentSidebarOversightMenuProps.PeerOption(
                peerEndpoint: seed.peerEndpoint,
                peerSessionID: seed.peerSessionID,
                displayName: seed.displayName,
                providerDisplayName: seed.providerDisplayName,
                menuLabel: observerLabels[seed.peerEndpoint] ?? seed.baseMenuLabel,
                fullIdentityDescription: seed.fullIdentityDescription,
                relationship: seed.relationship
            )
        }
        let targetOptions = targetSeeds.map { seed in
            AgentSidebarOversightMenuProps.PeerOption(
                peerEndpoint: seed.peerEndpoint,
                peerSessionID: seed.peerSessionID,
                displayName: seed.displayName,
                providerDisplayName: seed.providerDisplayName,
                menuLabel: targetLabels[seed.peerEndpoint] ?? seed.baseMenuLabel,
                fullIdentityDescription: seed.fullIdentityDescription,
                relationship: seed.relationship
            )
        }

        // Mark tooltips and the menu's jump sections read names from the same app-wide session
        // resolver as the candidate lists: a linked peer is always a name even when its exact
        // endpoint incarnation moved, and the compact ID is the last-resort fallback only.
        let inboundNames = inputs.inbound.items.map { item in
            inputs.inboundObserverEndpoints[item.linkID].flatMap {
                candidatesByEndpoint[$0]?.resolvedDisplayName
            } ?? candidatesBySessionID[item.observerSessionID]?.resolvedDisplayName
                ?? item.displayName ?? AgentMonitorSessionIDFormatter.short(item.observerSessionID)
        }
        let inboundSessionIDs = inputs.inbound.items.map(\.observerSessionID)
        let outboundNames = inputs.outbound.items.map { item in
            inputs.outboundTargetEndpoints[item.linkID].flatMap {
                candidatesByEndpoint[$0]?.resolvedDisplayName
            } ?? candidatesBySessionID[item.targetSessionID]?.resolvedDisplayName
                ?? item.displayName ?? AgentMonitorSessionIDFormatter.short(item.targetSessionID)
        }

        return AgentSidebarOversightMenuProps(
            targetEndpoint: rowEndpoint,
            targetSessionID: target.sessionID,
            targetDisplayName: target.resolvedDisplayName,
            observerOptions: observerOptions,
            createdByLabel: creatorSessionID
                .flatMap { candidatesBySessionID[$0]?.resolvedDisplayName } ?? createdByLabel,
            targetOptions: targetOptions,
            targetIneligibleReason: targetFailure?.uiMessage,
            observerIneligibleReason: observerReason,
            inboundObserverNames: inboundNames,
            inboundObserverSessionIDs: inboundSessionIDs,
            outboundTargetNames: outboundNames,
            creatorSessionID: creatorSessionID
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

    /// Own-workspace cohort first, then case/diacritic-insensitive name, then exact identity.
    private static func orderedBefore(
        _ lhs: Seed,
        _ rhs: Seed,
        currentWorkspaceID: UUID
    ) -> Bool {
        let lhsInWorkspace = lhs.peerEndpoint.workspaceID == currentWorkspaceID
        let rhsInWorkspace = rhs.peerEndpoint.workspaceID == currentWorkspaceID
        if lhsInWorkspace != rhsInWorkspace { return lhsInWorkspace }

        let lhsName = folded(lhs.displayName)
        let rhsName = folded(rhs.displayName)
        if lhsName != rhsName { return lhsName < rhsName }

        let lhsSession = lhs.peerSessionID.uuidString
        let rhsSession = rhs.peerSessionID.uuidString
        if lhsSession != rhsSession { return lhsSession < rhsSession }
        if lhs.peerEndpoint.windowID != rhs.peerEndpoint.windowID {
            return lhs.peerEndpoint.windowID < rhs.peerEndpoint.windowID
        }

        let lhsWorkspace = lhs.peerEndpoint.workspaceID.uuidString
        let rhsWorkspace = rhs.peerEndpoint.workspaceID.uuidString
        if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }

        let lhsTab = lhs.peerEndpoint.tabID.uuidString
        let rhsTab = rhs.peerEndpoint.tabID.uuidString
        if lhsTab != rhsTab { return lhsTab < rhsTab }

        let lhsBinding = lhs.peerEndpoint.persistentBindingGeneration?.uuidString ?? ""
        let rhsBinding = rhs.peerEndpoint.persistentBindingGeneration?.uuidString ?? ""
        if lhsBinding != rhsBinding { return lhsBinding < rhsBinding }
        return lhs.peerEndpoint.bindingTransitionGeneration
            < rhs.peerEndpoint.bindingTransitionGeneration
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: foldingLocale
        )
    }

    /// Widen only colliding labels, one exact component at a time, while keeping unique names clean.
    private static func collisionSafeLabels(
        for seeds: [Seed]
    ) -> [DomainAgentSessionLinkEndpointIdentity: String] {
        var labels = Dictionary(
            uniqueKeysWithValues: seeds.map { ($0.peerEndpoint, $0.baseMenuLabel) }
        )
        widenCollisions(in: &labels, seeds: seeds) { seed in
            "\(seed.baseMenuLabel) (\(shortUUID(seed.peerSessionID)))"
        }
        widenCollisions(in: &labels, seeds: seeds) { seed in
            "\(seed.baseMenuLabel) (\(shortUUID(seed.peerSessionID)), "
                + "window \(seed.peerEndpoint.windowID))"
        }
        widenCollisions(in: &labels, seeds: seeds) { seed in
            "\(seed.baseMenuLabel) (\(shortUUID(seed.peerSessionID)), "
                + "window \(seed.peerEndpoint.windowID), "
                + "tab \(shortUUID(seed.peerEndpoint.tabID)))"
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
            guard let label = labels[seed.peerEndpoint], counts[label, default: 0] > 1 else {
                continue
            }
            labels[seed.peerEndpoint] = replacement(seed)
        }
    }

    private static func shortUUID(_ id: UUID) -> String {
        let raw = id.uuidString
        return "\(raw.prefix(4))…\(raw.suffix(4))"
    }
}
