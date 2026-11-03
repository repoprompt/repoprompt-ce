import AppKit
import Combine
import SwiftUI

/// A workspace whose saves are refused because RepoPrompt could not make a recovery copy of tabs it
/// cannot read (#335). The latest local draft is kept in this window (and shown instead of a
/// reconciled projection) until a save reaches its durability point; it is not durable yet.
struct WorkspaceRecoveryBackupBlock: Equatable, Identifiable {
    /// The write phase that was refused. A saved-document block clears only when a saved commit
    /// covering the draft succeeds; a working-copy commit alone does not make the save durable.
    enum Phase: Equatable {
        case working
        case saved
    }

    let id: UUID
    let workspaceID: UUID
    var reason: String
    var phase: Phase
    /// The latest local draft whose save was refused.
    var draft: WorkspaceModel
    /// The manager state version the draft corresponds to. A save that captured at least this
    /// version and reached the blocked phase's durability point clears the block.
    var draftStateVersion: Int
    /// The canonical contents the draft descends from, and their digest. Newer canonical contents
    /// are merged onto the draft at compose-tab level; without a known base they conflict.
    var base: WorkspaceModel?
    var baseDigest: String?
    /// Non-empty when newer canonical contents changed what the draft also changed. Saving is
    /// refused (fail closed) until the user discards the draft.
    var conflictingTabIDs: [UUID]

    var isConflicted: Bool {
        !conflictingTabIDs.isEmpty
    }

    init(
        workspaceID: UUID,
        reason: String,
        phase: Phase,
        draft: WorkspaceModel,
        draftStateVersion: Int,
        baseDigest: String?
    ) {
        id = UUID()
        self.workspaceID = workspaceID
        self.reason = reason
        self.phase = phase
        self.draft = draft
        self.draftStateVersion = draftStateVersion
        base = nil
        self.baseDigest = baseDigest
        conflictingTabIDs = []
    }
}

/// Three-way merge of a blocked draft onto newer canonical contents, at compose-tab level. Never
/// silently overwrites a newer change: a tab (or the workspace's other fields, or the stash)
/// changed on both sides to different values is a conflict.
enum WorkspaceRecoveryDraftMerge {
    enum Result: Equatable {
        case merged(WorkspaceModel)
        /// IDs of conflicting compose tabs; the workspace ID stands for non-tab fields or stash.
        case conflict([UUID])
    }

    static func merge(base: WorkspaceModel, draft: WorkspaceModel, canonical: WorkspaceModel) -> Result {
        var conflicts: [UUID] = []
        var merged = draft

        let baseFields = nonTabFields(base)
        let draftFields = nonTabFields(draft)
        let canonicalFields = nonTabFields(canonical)
        if draftFields == baseFields {
            merged = canonical
            merged.composeTabs = draft.composeTabs
            merged.activeComposeTabID = draft.activeComposeTabID
            merged.stashedTabs = draft.stashedTabs
        } else if canonicalFields != baseFields, canonicalFields != draftFields {
            conflicts.append(draft.id)
        }

        if draft.stashedTabs == base.stashedTabs {
            merged.stashedTabs = canonical.stashedTabs
        } else if canonical.stashedTabs != base.stashedTabs, canonical.stashedTabs != draft.stashedTabs {
            if !conflicts.contains(draft.id) { conflicts.append(draft.id) }
        }

        let baseTabs = Dictionary(base.composeTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let draftTabs = Dictionary(draft.composeTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let canonicalTabs = Dictionary(canonical.composeTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let order = mergedTabOrder(
            base: base.composeTabs.map(\.id),
            draft: draft.composeTabs.map(\.id),
            canonical: canonical.composeTabs.map(\.id)
        ) else {
            return .conflict([draft.id])
        }
        var tabs: [ComposeTabState] = []
        for id in order {
            let baseTab = baseTabs[id]
            let draftTab = draftTabs[id]
            let canonicalTab = canonicalTabs[id]
            let resolved: ComposeTabState?
            if draftTab == baseTab {
                resolved = canonicalTab
            } else if canonicalTab == baseTab || canonicalTab == draftTab {
                resolved = draftTab
            } else {
                conflicts.append(id)
                resolved = draftTab
            }
            if let resolved { tabs.append(resolved) }
        }
        guard conflicts.isEmpty else { return .conflict(conflicts) }
        guard !tabs.isEmpty else { return .conflict([draft.id]) }
        merged.composeTabs = tabs
        let ids = Set(tabs.map(\.id))
        if let active = draft.activeComposeTabID, ids.contains(active) {
            merged.activeComposeTabID = active
        } else if let active = canonical.activeComposeTabID, ids.contains(active) {
            merged.activeComposeTabID = active
        } else {
            merged.activeComposeTabID = tabs.first?.id
        }
        return .merged(merged)
    }

    /// Tab order merged against the base: a side that reordered the tabs it shares with the base
    /// keeps its order, and the other side's new tabs follow. Both sides reordering the tabs they
    /// all share differently is a conflict (nil).
    static func mergedTabOrder(base: [UUID], draft: [UUID], canonical: [UUID]) -> [UUID]? {
        func relative(_ order: [UUID], to other: [UUID]) -> [UUID] {
            let members = Set(other)
            return order.filter { members.contains($0) }
        }
        let draftReordered = relative(draft, to: base) != relative(base, to: draft)
        let canonicalReordered = relative(canonical, to: base) != relative(base, to: canonical)
        if draftReordered, canonicalReordered {
            let shared = Set(base).intersection(draft).intersection(canonical)
            let draftShared = draft.filter { shared.contains($0) }
            let canonicalShared = canonical.filter { shared.contains($0) }
            guard draftShared == canonicalShared else { return nil }
        }
        if draftReordered {
            return draft + canonical.filter { !draft.contains($0) }
        }
        return canonical + draft.filter { !canonical.contains($0) }
    }

    /// Everything except compose tabs, the active tab, the stash, and modification timestamps.
    private static func nonTabFields(_ workspace: WorkspaceModel) -> WorkspaceModel {
        var fields = workspace
        fields.composeTabs = []
        fields.activeComposeTabID = nil
        fields.stashedTabs = []
        fields.dateModified = .distantPast
        fields.lastUsed = .distantPast
        return fields
    }
}

/// Banner for the active workspace's recovery-backup block, with one bounded Retry per press.
struct WorkspaceRecoveryBackupBlockBanner: View {
    let workspaceManager: WorkspaceManagerViewModel

    @State private var block: WorkspaceRecoveryBackupBlock?
    @State private var isRetrying = false
    @State private var retryFailed = false

    var body: some View {
        Group {
            if let block {
                content(block)
            }
        }
        // Narrow subscription: the banner never observes the whole workspace manager.
        .onReceive(
            workspaceManager.$recoveryBackupBlocks
                .combineLatest(workspaceManager.$activeWorkspaceID.removeDuplicates())
                .map { blocks, activeID in activeID.flatMap { blocks[$0] } }
        ) { current in
            if current?.id != block?.id {
                retryFailed = false
            }
            block = current
        }
    }

    private func content(_ block: WorkspaceRecoveryBackupBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(Self.message(for: block))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if retryFailed {
                Text("Saving is still blocked. " + WorkspaceRecoveryBackupReason(raw: block.reason).guidance)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if block.isConflicted {
                    Button("Discard my changes") {
                        workspaceManager.discardRecoveryBlockedDraft(workspaceID: block.workspaceID)
                    }
                } else {
                    Button(isRetrying ? "Retrying…" : "Retry") {
                        retry(block.workspaceID)
                    }
                    .disabled(isRetrying)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        workspaceManager.workspaceFileURL(for: block.draft)
                    ])
                }
                .buttonStyle(.borderless)
                .hoverTooltip("Show this workspace's folder in Finder")
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.orange.opacity(0.8), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.orange)
                .frame(width: 4)
                .padding(.vertical, 6)
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
    }

    static func message(for block: WorkspaceRecoveryBackupBlock) -> String {
        let reason = WorkspaceRecoveryBackupReason(raw: block.reason)
        if block.isConflicted {
            return "Changes to this workspace aren't being saved: \(reason.summary). "
                + "Your changes are kept only in this window. \(reason.guidance)"
        }
        return "Changes to this workspace aren't being saved. RepoPrompt couldn't save a recovery copy of "
            + "tabs it couldn't read: \(reason.summary). Your latest changes are kept only in this window "
            + "until a save succeeds. \(reason.guidance)"
    }

    private func retry(_ workspaceID: UUID) {
        isRetrying = true
        Task { @MainActor in
            let saved = await workspaceManager.retryRecoveryBackupBlockedSave(workspaceID: workspaceID)
            isRetrying = false
            retryFailed = !saved
        }
    }
}
