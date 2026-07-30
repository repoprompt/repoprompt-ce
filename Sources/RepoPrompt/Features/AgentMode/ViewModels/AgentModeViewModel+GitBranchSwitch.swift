import Foundation

@MainActor
extension AgentModeViewModel {
    func isAgentRunActive(tabID: UUID?) -> Bool {
        guard let tabID,
              let session = sessions[tabID]
        else { return false }
        return session.runState.isActive || tabsWithActiveAgentRun.contains(tabID)
    }

    func switchGitBranchFromWorkspaceRoot(
        _ row: AgentWorkspaceRootRow,
        preflight: GitBranchSwitchPreflight,
        gitViewModel: GitViewModel,
        currentTabID: UUID?
    ) async throws -> GitBranchSwitchResult {
        let activeRunAtSwitchStart = isAgentRunActive(tabID: currentTabID)
        let result = try await gitViewModel.switchGitBranch(
            GitBranchSwitchRequest(
                branchName: preflight.targetBranch,
                expectedCurrentBranch: preflight.currentBranch,
                expectedCurrentHead: preflight.currentHead
            ),
            forRootPath: row.fullPath,
            standardizedRootPath: row.standardizedFullPath
        )
        guard result.didSwitch else { return result }
        _ = await workspaceManager?.refreshAfterCheckoutMutation(rootPath: result.rootPath)
        recordSuccessfulInAppGitBranchSwitch(
            row: row,
            result: result,
            currentTabID: currentTabID,
            activeRunAtSwitchStart: activeRunAtSwitchStart
        )
        return result
    }

    private func recordSuccessfulInAppGitBranchSwitch(
        row: AgentWorkspaceRootRow,
        result: GitBranchSwitchResult,
        currentTabID: UUID?,
        activeRunAtSwitchStart: Bool
    ) {
        guard let currentTabID,
              let session = sessions[currentTabID]
        else { return }

        let didUpdateBinding = updateMatchingBranchSwitchBindingMetadata(
            session: session,
            row: row,
            result: result
        )
        let switchedCheckoutIsRelevant = Self.branchSwitchIsProviderContextRelevant(
            worktreeBindings: session.worktreeBindings,
            switchedCheckoutCandidatePaths: branchSwitchCandidatePaths(row: row, result: result),
            isPrimaryRoot: row.isPrimary,
            didUpdateMatchingWorktreeBinding: didUpdateBinding
        )
        let shouldAppendNote = switchedCheckoutIsRelevant && (session.deservesProviderVisibleBranchSwitchNote || activeRunAtSwitchStart)
        if shouldAppendNote {
            session.appendItem(.system(branchSwitchSystemNote(
                row: row,
                result: result,
                activeRunAtSwitchStart: activeRunAtSwitchStart
            )))
            updateBindingsFromSession(session)
        } else if didUpdateBinding {
            session.isDirty = true
        }

        if shouldAppendNote || didUpdateBinding {
            updateWorktreeBindingSummariesInIndex(for: session)
            syncSidebarUIState(refresh: true, reason: .metadataUpdated)
            syncStatusPillsUIState()
            scheduleSave(for: session.tabID)
            requestUIRefresh(tabID: session.tabID, urgent: true)
        }
    }

    private func branchSwitchCandidatePaths(row: AgentWorkspaceRootRow, result: GitBranchSwitchResult) -> [String] {
        [
            row.gitContext?.worktreePath,
            result.rootPath,
            row.fullPath
        ].compactMap(\.self)
    }

    static func branchSwitchIsProviderContextRelevant(
        worktreeBindings: [AgentSessionWorktreeBinding],
        switchedCheckoutCandidatePaths: [String],
        isPrimaryRoot: Bool,
        didUpdateMatchingWorktreeBinding: Bool
    ) -> Bool {
        if didUpdateMatchingWorktreeBinding {
            return true
        }
        let candidateIdentities = Set(switchedCheckoutCandidatePaths.compactMap(CheckoutPathIdentity.init))
        guard !candidateIdentities.isEmpty else { return false }
        guard !worktreeBindings.isEmpty else { return isPrimaryRoot }

        let boundWorktreeIdentities = Set(worktreeBindings.compactMap { CheckoutPathIdentity($0.worktreeRootPath) })
        if !candidateIdentities.isDisjoint(with: boundWorktreeIdentities) {
            return true
        }

        let boundLogicalIdentities = Set(worktreeBindings.compactMap { CheckoutPathIdentity($0.logicalRootPath) })
        if !candidateIdentities.isDisjoint(with: boundLogicalIdentities) {
            return false
        }

        return isPrimaryRoot
    }

    private func branchSwitchSystemNote(
        row: AgentWorkspaceRootRow,
        result: GitBranchSwitchResult,
        activeRunAtSwitchStart: Bool
    ) -> String {
        let previous = result.previousBranch ?? GitShortRef.detachedLabel(head: result.previousHead)
        var text = "User switched Git branch for workspace root \"\(row.name)\" from \"\(previous)\" to \"\(result.newBranch)\" in \(row.gitContext?.worktreePath ?? result.rootPath) using RepoPrompt. Files in this checkout may have changed during the session."
        if activeRunAtSwitchStart {
            text += " The active run was not stopped, replayed, or rewritten."
        }
        return text
    }

    @discardableResult
    private func updateMatchingBranchSwitchBindingMetadata(
        session: TabSession,
        row: AgentWorkspaceRootRow,
        result: GitBranchSwitchResult
    ) -> Bool {
        let update = Self.updatedWorktreeBindingsAfterBranchSwitch(
            session.worktreeBindings,
            switchedCheckoutCandidatePaths: branchSwitchCandidatePaths(row: row, result: result),
            branch: result.newBranch,
            head: result.newHead
        )
        guard update.didUpdate else { return false }
        session.worktreeBindings = update.bindings
        session.isDirty = true
        return true
    }

    static func updatedWorktreeBindingsAfterBranchSwitch(
        _ bindings: [AgentSessionWorktreeBinding],
        switchedCheckoutCandidatePaths: [String],
        branch: String?,
        head: String?
    ) -> (bindings: [AgentSessionWorktreeBinding], didUpdate: Bool) {
        guard !bindings.isEmpty else { return (bindings, false) }
        let candidateIdentities = Set(switchedCheckoutCandidatePaths.compactMap(CheckoutPathIdentity.init))
        guard !candidateIdentities.isEmpty else { return (bindings, false) }

        var didUpdate = false
        let updatedBindings = bindings.map { binding in
            guard let bindingIdentity = CheckoutPathIdentity(binding.worktreeRootPath),
                  candidateIdentities.contains(bindingIdentity)
            else { return binding }
            let updated = binding.updatingCheckout(branch: branch, head: head)
            if updated != binding {
                didUpdate = true
            }
            return updated
        }
        return (updatedBindings, didUpdate)
    }

    static func executionWorktreeSelection(from worktree: GitWorktreeDescriptor) -> AgentExecutionWorktreeSelection {
        let fallbackLabel = worktree.name ?? worktree.branch ?? (worktree.isMain ? "main" : nil)
        let identity = GlobalSettingsStore.shared.resolvedWorktreeVisualIdentity(
            repositoryID: worktree.repository.repositoryID,
            worktreeID: worktree.worktreeID,
            fallbackLabel: fallbackLabel
        )
        return AgentExecutionWorktreeSelection(
            repositoryID: worktree.repository.repositoryID,
            repoKey: worktree.repository.repoKey,
            worktreeID: worktree.worktreeID,
            path: worktree.path,
            name: worktree.name,
            branch: worktree.branch,
            head: worktree.head,
            isDetached: worktree.isDetached,
            label: identity.label ?? fallbackLabel ?? URL(fileURLWithPath: worktree.path).lastPathComponent,
            colorHex: identity.colorHex,
            isLocked: worktree.isLocked,
            lockReason: worktree.lockReason,
            isPrunable: worktree.isPrunable,
            prunableReason: worktree.prunableReason
        )
    }

    static func dedupedExecutionWorktreeSelections(
        _ selections: [AgentExecutionWorktreeSelection]
    ) -> [AgentExecutionWorktreeSelection] {
        let identityDeduped = dedupeExecutionWorktrees(selections) { selection in
            "\(selection.repositoryID)::\(selection.worktreeID)"
        }
        return dedupeExecutionWorktrees(identityDeduped) { selection in
            "\(selection.repositoryID)::\(CheckoutPathIdentity.canonicalPathOrOriginal(selection.path))"
        }
    }

    private static func dedupeExecutionWorktrees(
        _ selections: [AgentExecutionWorktreeSelection],
        key: (AgentExecutionWorktreeSelection) -> String
    ) -> [AgentExecutionWorktreeSelection] {
        var representatives: [String: AgentExecutionWorktreeSelection] = [:]
        for selection in selections {
            let dedupeKey = key(selection)
            guard let existing = representatives[dedupeKey] else {
                representatives[dedupeKey] = selection
                continue
            }
            representatives[dedupeKey] = preferredExecutionWorktreeRepresentative(existing, selection)
        }
        return Array(representatives.values)
    }

    private static func preferredExecutionWorktreeRepresentative(
        _ lhs: AgentExecutionWorktreeSelection,
        _ rhs: AgentExecutionWorktreeSelection
    ) -> AgentExecutionWorktreeSelection {
        let lhsRank = executionWorktreeRepresentativeRank(lhs)
        let rhsRank = executionWorktreeRepresentativeRank(rhs)
        if lhsRank.prunable != rhsRank.prunable {
            return lhsRank.prunable < rhsRank.prunable ? lhs : rhs
        }
        if lhsRank.hasBranchOrHead != rhsRank.hasBranchOrHead {
            return lhsRank.hasBranchOrHead < rhsRank.hasBranchOrHead ? lhs : rhs
        }
        if lhsRank.hasName != rhsRank.hasName {
            return lhsRank.hasName < rhsRank.hasName ? lhs : rhs
        }
        return CheckoutPathIdentity.canonicalPathOrOriginal(lhs.path) <= CheckoutPathIdentity.canonicalPathOrOriginal(rhs.path) ? lhs : rhs
    }

    private static func executionWorktreeRepresentativeRank(
        _ selection: AgentExecutionWorktreeSelection
    ) -> (prunable: Int, hasBranchOrHead: Int, hasName: Int) {
        (
            prunable: selection.isPrunable ? 1 : 0,
            hasBranchOrHead: (selection.branch != nil || selection.head != nil) ? 0 : 1,
            hasName: selection.name == nil ? 1 : 0
        )
    }
}
