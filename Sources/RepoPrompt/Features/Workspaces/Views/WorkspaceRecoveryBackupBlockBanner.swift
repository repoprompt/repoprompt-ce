import AppKit
import Combine
import SwiftUI

/// A workspace whose saves are refused because RepoPrompt could not make a recovery copy of tabs it
/// cannot read (#335). The latest local draft is kept in this window (and shown instead of a
/// reconciled projection) until a save reaches its durability point; it is not durable yet.
struct WorkspaceRecoveryBackupBlock: Equatable, Identifiable {
    let id: UUID
    let workspaceID: UUID
    var reason: String
    /// The latest local draft whose save was refused.
    var draft: WorkspaceModel
    /// The manager state version the draft corresponds to. A save that captured at least this
    /// version and became durable clears the block.
    var draftStateVersion: Int

    init(workspaceID: UUID, reason: String, draft: WorkspaceModel, draftStateVersion: Int) {
        id = UUID()
        self.workspaceID = workspaceID
        self.reason = reason
        self.draft = draft
        self.draftStateVersion = draftStateVersion
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
                Text(Self.message(reason: block.reason))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if retryFailed {
                Text("Saving is still blocked. Free disk space or fix the folder's permissions, then try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(isRetrying ? "Retrying…" : "Retry") {
                    retry(block.workspaceID)
                }
                .disabled(isRetrying)
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

    static func message(reason: String) -> String {
        "Changes to this workspace aren't being saved. RepoPrompt couldn't save a recovery copy of "
            + "tabs it couldn't read (\(reason)). Your latest changes are kept only in this window "
            + "until a save succeeds. Free disk space or check the folder's permissions, then Retry."
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
