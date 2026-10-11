import Foundation
import RepoPromptDomainRuntime

extension AgentSessionRow {
    /// Action wiring for one native (`StableMenuButton`) oversight menu presentation. The
    /// closures forward to the row's own handlers, which re-resolve current props and
    /// revalidate exact endpoints at click time — a frozen item tree is safe because every
    /// mutation is authority-checked when it fires, not when the menu opened.
    struct AgentSidebarOversightMenuActions {
        var openLinkedSession: (DomainAgentSessionLinkEndpointIdentity) -> Void = { _ in }
        var openCreator: (() -> Void)?
        var addInbound: (AgentSidebarOversightMenuProps.ObserverOption) -> Void = { _ in }
        var addOutbound: (AgentSidebarOversightMenuProps.TargetOption) -> Void = { _ in }
        var unlink: (
            _ observerEndpoint: DomainAgentSessionLinkEndpointIdentity,
            _ targetEndpoint: DomainAgentSessionLinkEndpointIdentity,
            _ reference: DomainAgentSessionLinkReference
        ) -> Void = { _, _, _ in }
        var presentChooseTargetSheet: () -> Void = {}
        var presentChooseOverseerSheet: () -> Void = {}
    }

    /// The immutable item tree the native (`StableMenuButton`) oversight presentations —
    /// mark click and hover affordance — build once per activation. The retained NSMenu then
    /// owns it for the presentation's lifetime, so sidebar invalidations cannot repopulate
    /// the open menu the way a re-rendered SwiftUI `Menu`'s content can (and did: cross-window
    /// projection publishes collapsed the menu mid-browse). Mirrors
    /// `sidebarOversightMenuContent` item-for-item; keep the two in sync.
    static func sidebarOversightMenuItems(
        _ menu: AgentSidebarOversightMenuProps,
        busyKeys: Set<AgentSidebarOversightActionKey>,
        actions: AgentSidebarOversightMenuActions
    ) -> [StableMenuItem] {
        let hasLinkedSections = !menu.linkedTargets.isEmpty || !menu.linkedObservers.isEmpty
        let hasTopSections = hasLinkedSections || menu.showsCreatedBySection

        func jumpItem(_ option: AgentSidebarOversightMenuProps.PeerOption) -> StableMenuItem {
            .action(
                option.menuLabel,
                imageSystemName: AgentOversightUICopy.jumpItemIcon,
                accessibilityHint: AgentOversightUICopy.openHint(option.menuLabel)
            ) {
                actions.openLinkedSession(option.peerEndpoint)
            }
        }

        var items: [StableMenuItem] = []

        if !hasTopSections {
            items.append(.header(AgentOversightUICopy.oversightMenuHeader))
        }

        // "Overseen by" leads "Overseeing": the hierarchy reads top-down — this session's own
        // overseers first, then the sessions it oversees.
        if !menu.linkedObservers.isEmpty {
            items.append(.header(
                menu.creatorIsSoleOverseer
                    ? AgentOversightUICopy.createdAndOverseenBySectionLabel
                    : AgentOversightUICopy.overseenBySectionLabel
            ))
            items += menu.linkedObservers.map(jumpItem)
        }
        if !menu.linkedTargets.isEmpty {
            items.append(.header(AgentOversightUICopy.overseeingSectionLabel))
            items += menu.linkedTargets.map(jumpItem)
        }
        if menu.showsCreatedBySection, let creatorLabel = menu.createdByLabel {
            items.append(.header(AgentOversightUICopy.createdBySectionLabel))
            items.append(.action(
                creatorLabel,
                imageSystemName: AgentOversightUICopy.jumpItemIcon,
                accessibilityHint: AgentOversightUICopy.openHint(creatorLabel)
            ) {
                actions.openCreator?()
            })
        }

        if hasTopSections {
            items.append(.separator)
        }

        // "Link overseer" leads "Oversee" — the same top-down hierarchy as the linked sections.
        var overseeByItems: [StableMenuItem] = []
        if let reason = menu.targetIneligibleReason {
            overseeByItems.append(.message(reason))
        }
        if menu.availableObservers.isEmpty, menu.targetIneligibleReason == nil {
            overseeByItems.append(.message(AgentOversightUICopy.noEligibleOverseers))
        } else {
            overseeByItems += menu.availableObservers.map { option in
                let busy = busyKeys.contains(.add(
                    observerEndpoint: option.peerEndpoint,
                    targetEndpoint: menu.targetEndpoint
                ))
                return .action(
                    option.menuLabel,
                    isEnabled: !busy,
                    imageSystemName: busy ? "hourglass" : nil,
                    accessibilityLabel: option.menuLabel,
                    accessibilityValue: busy ? "In progress" : nil,
                    accessibilityHint: option.fullIdentityDescription
                ) {
                    actions.addInbound(option)
                }
            }
        }
        overseeByItems.append(.separator)
        overseeByItems.append(.action(
            AgentOversightUICopy.sessionIDMenuItem,
            isEnabled: menu.targetIneligibleReason == nil
        ) {
            actions.presentChooseOverseerSheet()
        })
        items.append(.submenu(
            AgentOversightUICopy.overseeByTitle,
            accessibilityLabel: AgentOversightUICopy.overseeByTitle,
            accessibilityValue: AgentOversightUICopy.overseeByMenuAccessibilityValue(
                overseenByCount: menu.linkedObservers.count,
                availableCount: menu.availableObservers.count
            ),
            items: overseeByItems
        ))

        var overseeNewItems: [StableMenuItem] = []
        if let reason = menu.observerIneligibleReason {
            overseeNewItems.append(.message(reason))
        }
        if menu.availableTargets.isEmpty, menu.observerIneligibleReason == nil {
            overseeNewItems.append(.message(AgentOversightUICopy.noSessionsToOversee))
        } else {
            overseeNewItems += menu.availableTargets.map { option in
                let busy = busyKeys.contains(.add(
                    observerEndpoint: menu.targetEndpoint,
                    targetEndpoint: option.peerEndpoint
                ))
                return .action(
                    option.menuLabel,
                    isEnabled: !busy && menu.observerIneligibleReason == nil,
                    imageSystemName: busy ? "hourglass" : nil,
                    accessibilityLabel: option.menuLabel,
                    accessibilityValue: busy ? "In progress" : nil,
                    accessibilityHint: option.fullIdentityDescription
                ) {
                    actions.addOutbound(option)
                }
            }
        }
        overseeNewItems.append(.separator)
        overseeNewItems.append(.action(
            AgentOversightUICopy.sessionIDMenuItem,
            isEnabled: menu.observerIneligibleReason == nil
        ) {
            actions.presentChooseTargetSheet()
        })
        items.append(.submenu(
            AgentOversightUICopy.overseeNewTitle,
            accessibilityLabel: AgentOversightUICopy.overseeNewTitle,
            accessibilityValue: AgentOversightUICopy.overseeMenuAccessibilityValue(
                overseeingCount: menu.linkedTargets.count,
                availableCount: menu.availableTargets.count
            ),
            items: overseeNewItems
        ))

        if hasLinkedSections {
            var unlinkItems: [StableMenuItem] = []
            if !menu.linkedObservers.isEmpty {
                unlinkItems.append(.header(AgentOversightUICopy.unlinkOverseerSectionLabel))
                unlinkItems += menu.linkedObservers.compactMap { option in
                    guard case let .linked(reference, _) = option.relationship else { return nil }
                    let busy = busyKeys.contains(.unlink(
                        observerEndpoint: option.peerEndpoint,
                        targetEndpoint: menu.targetEndpoint,
                        reference: reference
                    ))
                    return .action(
                        option.menuLabel,
                        isEnabled: !busy,
                        imageSystemName: busy ? "hourglass" : nil,
                        accessibilityLabel: AgentOversightUICopy.unlinkAccessibilityLabel(option.menuLabel),
                        accessibilityValue: busy ? "In progress" : nil,
                        accessibilityHint: option.fullIdentityDescription
                    ) {
                        actions.unlink(option.peerEndpoint, menu.targetEndpoint, reference)
                    }
                }
            }
            if !menu.linkedTargets.isEmpty {
                unlinkItems.append(.header(AgentOversightUICopy.unlinkOverseenSectionLabel))
                unlinkItems += menu.linkedTargets.compactMap { option in
                    guard case let .linked(reference, _) = option.relationship else { return nil }
                    let busy = busyKeys.contains(.unlink(
                        observerEndpoint: menu.targetEndpoint,
                        targetEndpoint: option.peerEndpoint,
                        reference: reference
                    ))
                    return .action(
                        option.menuLabel,
                        isEnabled: !busy,
                        imageSystemName: busy ? "hourglass" : nil,
                        accessibilityLabel: AgentOversightUICopy.unlinkAccessibilityLabel(option.menuLabel),
                        accessibilityValue: busy ? "In progress" : nil,
                        accessibilityHint: option.fullIdentityDescription
                    ) {
                        actions.unlink(menu.targetEndpoint, option.peerEndpoint, reference)
                    }
                }
            }
            items.append(.submenu(
                AgentOversightUICopy.unlinkTitle,
                accessibilityLabel: AgentOversightUICopy.unlinkTitle,
                accessibilityValue: AgentOversightUICopy.unlinkMenuAccessibilityValue(
                    linkCount: menu.linkedTargets.count + menu.linkedObservers.count
                ),
                items: unlinkItems
            ))
        }

        return items
    }
}
