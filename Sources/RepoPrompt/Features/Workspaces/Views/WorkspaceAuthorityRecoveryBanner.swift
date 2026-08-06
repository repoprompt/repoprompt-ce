import SwiftUI

/// Window-level recovery for workspace authority failures. The manager remains the sole UI
/// projection of domain health; this view never inspects or mutates workspace files directly.
struct WorkspaceAuthorityRecoveryBanner: View {
    @ObservedObject var workspaceManager: WorkspaceManagerViewModel

    @State private var isResolving = false
    @State private var confirmUseExternal = false
    @State private var actionError: String?

    var body: some View {
        if let issue = visibleIssue {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(for: issue))
                            .font(.callout.weight(.semibold))
                        Text(issue.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if let reason = issue.reason {
                            Text("Reason: \(reason)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let diagnostic = issue.diagnostic,
                           diagnostic != issue.reason
                        {
                            Text(diagnostic)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if issue.canResolveExternalConflict,
                       let workspaceID = issue.workspaceID
                    {
                        Button("Keep Local") {
                            resolve(workspaceID: workspaceID, acceptExternal: false)
                        }
                        .disabled(isResolving)
                        .hoverTooltip("Keep RepoPrompt's local working state; the next save replaces the external file")

                        Button("Use External…") {
                            confirmUseExternal = true
                        }
                        .buttonStyle(.borderless)
                        .disabled(isResolving)
                        .confirmationDialog(
                            "Use externally saved workspace state?",
                            isPresented: $confirmUseExternal,
                            titleVisibility: .visible
                        ) {
                            Button("Use External", role: .destructive) {
                                resolve(workspaceID: workspaceID, acceptExternal: true)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Local dirty workspace changes will be discarded. RepoPrompt will refuse this action if it would remove or rebind a live or pinned Agent tab.")
                        }
                    } else if issue.kind == .degradedReadOnly || issue.kind == .commandFailure {
                        Button("Retry") {
                            refresh()
                        }
                        .disabled(isResolving)
                    }
                    if isResolving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
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
    }

    private var visibleIssue: DomainWorkspaceAuthorityIssue? {
        guard let issue = workspaceManager.domainWorkspaceAuthorityIssue else { return nil }
        guard issue.workspaceID == nil || issue.workspaceID == workspaceManager.activeWorkspaceID else {
            return nil
        }
        return issue
    }

    private func title(for issue: DomainWorkspaceAuthorityIssue) -> String {
        switch issue.kind {
        case .externalConflict: "Workspace changes need a decision"
        case .degradedReadOnly: "Workspace is read-only"
        case .removed: "Workspace is unavailable"
        case .commandFailure: "Workspace change failed"
        case .projectionFailure: "Workspace state could not be displayed"
        }
    }

    private func resolve(workspaceID: UUID, acceptExternal: Bool) {
        isResolving = true
        actionError = nil
        Task { @MainActor in
            let resolved = await workspaceManager.resolveDomainWorkspaceConflict(
                workspaceID: workspaceID,
                acceptExternal: acceptExternal
            )
            if !resolved {
                actionError = workspaceManager.domainWorkspaceAuthorityIssue?.diagnostic
                    ?? "The workspace conflict could not be resolved. No state was changed."
            }
            isResolving = false
        }
    }

    private func refresh() {
        isResolving = true
        actionError = nil
        Task { @MainActor in
            await workspaceManager.refreshDomainWorkspaceAuthority()
            isResolving = false
        }
    }
}
