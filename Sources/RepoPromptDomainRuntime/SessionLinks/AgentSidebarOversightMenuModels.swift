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
    /// Available choices are hidden when the row cannot currently observe.
    package let targetOptions: [PeerOption]

    /// Why the row cannot currently accept a new inbound link, or `nil` when it can.
    /// Rendered greyed-out in the Oversee-by menu instead of hiding the menu.
    package var targetIneligibleReason: String?
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

    // Cached status refreshes may retain peer choices while the live subject becomes ineligible.
    // Keep that fact separate from displayed reasons: a persistence overlay disables offered rows
    // in the renderer, but must not remove those rows or change their accessibility counts.
    private var subjectTargetIsEligible = true
    private var subjectObserverIsEligible = true

    package var linkedObservers: [ObserverOption] {
        observerOptions.filter {
            if case .linked = $0.relationship { return true }
            return false
        }
    }

    package var availableObservers: [ObserverOption] {
        guard subjectTargetIsEligible else { return [] }
        return observerOptions.filter { $0.relationship == .available }
    }

    package var linkedTargets: [TargetOption] {
        targetOptions.filter {
            if case .linked = $0.relationship { return true }
            return false
        }
    }

    package var availableTargets: [TargetOption] {
        guard subjectObserverIsEligible else { return [] }
        return targetOptions.filter { $0.relationship == .available }
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

    /// Refreshes only the subject's pure eligibility, retaining all peer choices for recovery.
    /// No peer walk: linked actions, ordering and accessibility labels stay unchanged.
    package func withSubjectEligibility(for candidate: AgentSessionLinkEndpointCandidate) -> AgentSidebarOversightMenuProps {
        var copy = self
        copy.targetIneligibleReason = AgentSessionLinkEndpointEligibility.targetResolveFailure(for: candidate)?.uiMessage
        copy.observerIneligibleReason = AgentSessionLinkEndpointEligibility.addDisabledReason(
            candidate.eligibilityInput,
            roleAllowsOutboundMonitoring: candidate.roleAllowsOutboundMonitoring
        )
        copy.subjectTargetIsEligible = copy.targetIneligibleReason == nil
        copy.subjectObserverIsEligible = copy.observerIneligibleReason == nil
        return copy
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
    fileprivate struct Seed {
        let peerEndpoint: DomainAgentSessionLinkEndpointIdentity
        let peerSessionID: UUID
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
            peerEndpoint: DomainAgentSessionLinkEndpointIdentity,
            peerSessionID: UUID,
            displayName: String,
            providerDisplayName: String?,
            locationLabel: String?,
            relationship: AgentSidebarOversightMenuProps.Relationship
        ) {
            self.peerEndpoint = peerEndpoint
            self.peerSessionID = peerSessionID
            self.displayName = displayName
            self.providerDisplayName = providerDisplayName
            self.locationLabel = locationLabel
            self.relationship = relationship
            let location = locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            baseMenuLabel = location.isEmpty ? displayName : "\(location): \(displayName)"
            foldedName = folded(displayName)
            sessionSortKey = peerSessionID.uuidString
            workspaceSortKey = peerEndpoint.workspaceID.uuidString
            tabSortKey = peerEndpoint.tabID.uuidString
            bindingSortKey = peerEndpoint.persistentBindingGeneration?.uuidString ?? ""
            fullIdentityDescription = "session \(sessionSortKey); window \(peerEndpoint.windowID); "
                + "workspace \(workspaceSortKey); tab \(tabSortKey); "
                + "binding \(bindingSortKey.isEmpty ? "unresolved" : bindingSortKey); "
                + "transition \(peerEndpoint.bindingTransitionGeneration)"
        }
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// Immutable preparation for one candidate snapshot, shared by every row in a refresh pass.
    package struct CandidateIndex {
        package let byEndpoint: [DomainAgentSessionLinkEndpointIdentity: AgentSessionLinkEndpointCandidate]
        package let firstBySessionID: [UUID: AgentSessionLinkEndpointCandidate]
        fileprivate let labelsAreUnique: Bool
        fileprivate let orderedPeers: [Seed]
        fileprivate let peersByWorkspace: [UUID: [Seed]]
        fileprivate let observerEligibleEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>
        fileprivate let targetEligibleEndpoints: Set<DomainAgentSessionLinkEndpointIdentity>

        package init(_ candidates: [AgentSessionLinkEndpointCandidate]) {
            // Choose representatives before sorting: descriptive lookups remain live first-match.
            byEndpoint = Dictionary(candidates.map { ($0.domainEndpoint, $0) }, uniquingKeysWith: { first, _ in first })
            firstBySessionID = Dictionary(candidates.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
            orderedPeers = byEndpoint.values.map { candidate in
                Seed(
                    peerEndpoint: candidate.domainEndpoint,
                    peerSessionID: candidate.sessionID,
                    displayName: candidate.resolvedDisplayName,
                    providerDisplayName: normalizedProvider(candidate.providerDisplayName),
                    locationLabel: candidate.locationLabel,
                    relationship: .available
                )
            }.sorted { orderedBefore($0, $1, currentWorkspaceID: nil) }
            labelsAreUnique = Set(orderedPeers.map(\.baseMenuLabel)).count == orderedPeers.count
            peersByWorkspace = Dictionary(grouping: orderedPeers, by: { $0.peerEndpoint.workspaceID })
            observerEligibleEndpoints = Set(byEndpoint.values.filter {
                AgentSessionLinkEndpointEligibility.addDisabledReason(
                    $0.eligibilityInput, roleAllowsOutboundMonitoring: $0.roleAllowsOutboundMonitoring
                ) == nil
            }.map(\.domainEndpoint))
            targetEligibleEndpoints = Set(byEndpoint.values.filter {
                AgentSessionLinkEndpointEligibility.targetResolveFailure(for: $0) == nil
            }.map(\.domainEndpoint))
        }
    }

    package static func make(
        target: AgentSessionLinkEndpointCandidate,
        inputs: DomainAgentSessionLinkEndpointProjectionInputs,
        candidates: [AgentSessionLinkEndpointCandidate],
        createdByLabel: String? = nil,
        creatorSessionID: UUID? = nil
    ) -> AgentSidebarOversightMenuProps {
        make(
            target: target,
            inputs: inputs,
            candidateIndex: CandidateIndex(candidates),
            createdByLabel: createdByLabel,
            creatorSessionID: creatorSessionID
        )
    }

    package static func make(
        target: AgentSessionLinkEndpointCandidate,
        inputs: DomainAgentSessionLinkEndpointProjectionInputs,
        candidateIndex: CandidateIndex,
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

        let candidatesByEndpoint = candidateIndex.byEndpoint
        let candidatesBySessionID = candidateIndex.firstBySessionID
        // Filtering this shared order preserves own-workspace-first without sorting N peers per row.
        let orderedPeers = (candidateIndex.peersByWorkspace[rowWorkspaceID] ?? [])
            + candidateIndex.orderedPeers.filter { $0.peerEndpoint.workspaceID != rowWorkspaceID }

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
        // New inbound links require an eligible target; a greyed reason replaces the list otherwise.
        if targetFailure == nil {
            for observer in orderedPeers {
                let observerEndpoint = observer.peerEndpoint
                guard observer.peerSessionID != target.sessionID,
                      !linkedObserverEndpoints.contains(observerEndpoint),
                      inputs.activeOutboundObserverEndpoints.contains(observerEndpoint),
                      candidateIndex.observerEligibleEndpoints.contains(observerEndpoint)
                else { continue }
                availableObservers.append(observer)
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
        // New outbound links require an eligible observer; a greyed reason replaces the list.
        if observerReason == nil {
            for peer in orderedPeers {
                let peerEndpoint = peer.peerEndpoint
                guard peer.peerSessionID != target.sessionID,
                      !linkedTargetEndpoints.contains(peerEndpoint),
                      candidateIndex.targetEligibleEndpoints.contains(peerEndpoint)
                else { continue }
                availableTargets.append(peer)
            }
        }

        // MARK: Ordering and labels

        // Inbound: one flat checkmark list — own workspace first, then folded name.
        let observerSeeds = mergeOrdered(
            linkedObservers.sorted { orderedBefore($0, $1, currentWorkspaceID: rowWorkspaceID) },
            availableObservers,
            currentWorkspaceID: rowWorkspaceID
        )
        // Outbound: ticked first, then own-workspace-first and folded name within each group.
        let targetSeeds = linkedTargets.sorted {
            orderedBefore($0, $1, currentWorkspaceID: rowWorkspaceID)
        } + availableTargets

        let observerLabels = collisionSafeLabels(for: observerSeeds, linked: linkedObservers, candidateIndex: candidateIndex)
        let targetLabels = collisionSafeLabels(for: targetSeeds, linked: linkedTargets, candidateIndex: candidateIndex)

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
        currentWorkspaceID: UUID?
    ) -> Bool {
        let lhsInWorkspace = lhs.peerEndpoint.workspaceID == currentWorkspaceID
        let rhsInWorkspace = rhs.peerEndpoint.workspaceID == currentWorkspaceID
        if lhsInWorkspace != rhsInWorkspace { return lhsInWorkspace }

        let lhsName = lhs.foldedName
        let rhsName = rhs.foldedName
        if lhsName != rhsName { return lhsName < rhsName }

        let lhsSession = lhs.sessionSortKey
        let rhsSession = rhs.sessionSortKey
        if lhsSession != rhsSession { return lhsSession < rhsSession }
        if lhs.peerEndpoint.windowID != rhs.peerEndpoint.windowID {
            return lhs.peerEndpoint.windowID < rhs.peerEndpoint.windowID
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
        return lhs.peerEndpoint.bindingTransitionGeneration
            < rhs.peerEndpoint.bindingTransitionGeneration
    }

    private static func mergeOrdered(_ linked: [Seed], _ available: [Seed], currentWorkspaceID: UUID) -> [Seed] {
        var result: [Seed] = []
        result.reserveCapacity(linked.count + available.count)
        var linkedIndex = 0
        var availableIndex = 0
        while linkedIndex < linked.count, availableIndex < available.count {
            if orderedBefore(available[availableIndex], linked[linkedIndex], currentWorkspaceID: currentWorkspaceID) {
                result.append(available[availableIndex])
                availableIndex += 1
            } else {
                result.append(linked[linkedIndex])
                linkedIndex += 1
            }
        }
        result.append(contentsOf: linked[linkedIndex...])
        result.append(contentsOf: available[availableIndex...])
        return result
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
            guard let candidate = candidateIndex.byEndpoint[seed.peerEndpoint] else { return false }
            return seed.displayName == candidate.resolvedDisplayName && seed.locationLabel == candidate.locationLabel
        }) {
            return [:]
        }
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
