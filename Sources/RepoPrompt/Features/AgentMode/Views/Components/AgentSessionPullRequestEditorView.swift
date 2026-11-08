import AppKit
import SwiftUI

/// One editor for sidebar/titlebar human actions. Its immutable target includes binding generations;
/// neither a tab switch nor a same-UUID rebind may redirect a pending edit.
struct AgentSessionPullRequestEditorView: View {
    let viewModel: AgentModeViewModel
    let target: AgentSessionLifecycleAuthority.MutationTarget
    let onClose: () -> Void
    @State private var snapshot: AgentSessionTitleSnapshot?
    @State private var baseTitle = ""
    @State private var url = ""
    @State private var errorText: String?
    @State private var isApplying = false
    @State private var confirmsReset = false

    private var canEdit: Bool {
        snapshot?.metadata == nil || snapshot?.metadata?.state != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session title and pull requests").font(.headline)
            if let snapshot {
                TextField("Permanent subject title", text: $baseTitle)
                    .disabled(!canEdit || isApplying)
                Button("Save title") { apply(.humanRename(baseTitle)) }
                    .disabled(!canEdit || isApplying || baseTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("PR numbers decorate this title; changing the subject does not remove them.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if !canEdit {
                    Text("Title metadata is unreadable or from a newer version. The stored title is preserved.")
                    Text(snapshot.name).textSelection(.enabled)
                    if snapshot.metadata?.isMalformedCurrentVersion == true {
                        Button("Reset title metadata…", role: .destructive) { confirmsReset = true }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(snapshot.metadata?.state?.pullRequests ?? [], id: \.identity) { association in
                                HStack {
                                    Text(association.identity.url).textSelection(.enabled)
                                    Spacer()
                                    Text(association.provenance).font(.caption).foregroundStyle(.secondary)
                                    Button("Remove") { apply(.correct(add: [], remove: [association.identity], human: true)) }
                                        .disabled(isApplying)
                                }
                            }
                        }
                    }.frame(maxHeight: 180)
                    HStack {
                        TextField("https://github.com/owner/repo/pull/123", text: $url)
                        Button("Add PR") {
                            do {
                                let report = try AgentSessionPullRequestEvidence.report(url: url, relationship: "related", provenance: "humanAssociation", trustedHosts: viewModel.trustedPullRequestHosts)
                                apply(.associate([report], human: true))
                            } catch { errorText = error.localizedDescription }
                        }.disabled(isApplying || url.isEmpty || target.identity?.sessionID == nil)
                    }
                    Text("Associations are local metadata, not GitHub verification. Remove then add to correct a mistaken link.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { ProgressView("Loading exact session…") }
            if let errorText { Text(errorText).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Reload") { Task { await load() } }.disabled(isApplying)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { await load() }
        .confirmationDialog("Reset unreadable current-version title metadata?", isPresented: $confirmsReset) {
            Button("Preserve recovery copy and reset", role: .destructive) { reset() }
        } message: {
            Text("The full visible title will be kept, but unreadable PR associations will no longer be structured. The original session bytes must be backed up successfully first.")
        }
    }

    @MainActor
    private func load() async {
        do {
            try viewModel.validateSessionTitleEditorTarget(target)
            let current = try await viewModel.currentSessionTitle(tabID: target.tabID)
            try viewModel.validateSessionTitleEditorTarget(target)
            snapshot = current
            baseTitle = current.metadata?.state?.baseTitle ?? current.name
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func apply(_ command: AgentSessionTitleCommand) {
        guard let snapshot else { return }
        isApplying = true
        Task { @MainActor in
            defer { isApplying = false }
            do {
                let after = try await viewModel.applySessionTitleEditorCommand(command, target: target, expectedRevision: snapshot.revision)
                self.snapshot = after
                baseTitle = after.metadata?.state?.baseTitle ?? after.name
                url = ""
                errorText = nil
            } catch { errorText = error.localizedDescription + ". Reload before retrying a conflicting edit." }
        }
    }

    @MainActor
    private func reset() {
        guard let snapshot else { return }
        isApplying = true
        Task { @MainActor in
            defer { isApplying = false }
            do {
                self.snapshot = try await viewModel.resetSessionTitleMetadata(target: target, expectedRevision: snapshot.revision)
                baseTitle = self.snapshot?.name ?? ""
                errorText = nil
            } catch { errorText = error.localizedDescription }
        }
    }
}

@MainActor
enum AgentSessionPullRequestEditorPresenter {
    static func present(
        viewModel: AgentModeViewModel,
        tabID: UUID,
        sessionID: UUID?,
        workspaceID: UUID,
        expectedBinding: AgentSessionRestorationBindingToken? = nil
    ) {
        guard expectedBinding == nil || viewModel.sessions[tabID]?.currentRestorationBindingToken == expectedBinding else { return }
        guard viewModel.workspaceManager?.activeWorkspaceID == workspaceID,
              let parent = WindowStatesManager.shared.window(withID: viewModel.windowID)?.nsWindow,
              parent.attachedSheet == nil,
              let target = try? viewModel.resolveAgentSessionLifecycleMutationTarget(tabID: tabID, expectedSessionID: sessionID, intent: .setStatus)
        else { return }
        let panel = NSPanel()
        panel.styleMask = [.titled, .closable]
        panel.title = "Session details"
        panel.contentViewController = NSHostingController(rootView: AgentSessionPullRequestEditorView(viewModel: viewModel, target: target) { [weak panel, weak parent] in
            guard let panel else { return }
            parent?.endSheet(panel)
            panel.close()
        })
        parent.beginSheet(panel)
    }
}
