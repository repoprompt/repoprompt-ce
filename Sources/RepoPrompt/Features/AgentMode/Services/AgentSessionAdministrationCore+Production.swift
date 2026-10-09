import Foundation

extension AgentSessionAdministrationCore {
    /// The app's single administration core (the one authority check).
    ///
    /// Its projector also counts worktrees created under a scope and not yet released, so
    /// `maxWorktrees` sees unbound owned worktrees. Handlers are registered through the
    /// `AgentSessionAdministrationFrontDoor`, which forwards each one to this core.
    static func makeProduction(
        scopes: DelegationScopeRuntime,
        worktreeOwnership: WorktreeOwnershipStore
    ) -> AgentSessionAdministrationCore {
        AgentSessionAdministrationCore(
            scopes: scopes,
            projector: SpawnProvenanceDelegationMembershipProjector.production(worktreeOwnership: worktreeOwnership)
        )
    }
}

extension SpawnProvenanceDelegationMembershipProjector {
    static func production(worktreeOwnership: WorktreeOwnershipStore) -> SpawnProvenanceDelegationMembershipProjector {
        var projector = SpawnProvenanceDelegationMembershipProjector(source: OpenWindowsDelegationProvenanceSource())
        projector.ownedUnreleasedWorktreeIDs = { worktreeOwnership.ownedUnreleasedWorktreeIDs(createdBy: $0) }
        return projector
    }
}

extension AgentSessionAdministrationFrontDoor {
    /// Registers the structure, lifecycle, and worktree-on-behalf handlers (Lane C) through the front
    /// door, so they get the same filter/preview/idempotency/apply-on-approval shaping as the
    /// organizing ops while the core keeps the single authority check.
    func registerStructureHandlers(
        scopes: DelegationScopeRuntime,
        worktreeOwnership: WorktreeOwnershipStore,
        projector: (any DelegationMembershipProjector)? = nil,
        structureHost: (any SessionAdminStructureHost)? = nil,
        worktreeHost: (any SessionAdminWorktreeHost)? = nil
    ) {
        let structureHost = structureHost ?? SessionAdminWindowsStructureHost()
        let worktreeHost = worktreeHost ?? SessionAdminWindowsWorktreeHost()
        let context = SessionAdminHandlerContext(
            scopes: scopes,
            projector: projector ?? SpawnProvenanceDelegationMembershipProjector.production(worktreeOwnership: worktreeOwnership),
            displayName: { DelegationDisplayNames.sessionTitle($0) }
        )
        register(SessionAdminRestructureHandler(context: context, host: structureHost))
        register(SessionAdminLifecycleHandler(context: context, host: structureHost))
        register(SessionAdminWorktreeHandler(context: context, host: worktreeHost, ownership: worktreeOwnership))
    }
}
