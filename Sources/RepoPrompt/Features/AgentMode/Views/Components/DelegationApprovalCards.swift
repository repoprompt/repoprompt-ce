import RepoPromptDomainRuntime
import SwiftUI

// MARK: - Delegation approval cards

//
// User-facing approval surfaces for delegation scopes (design §2.4, §2.5). Both are non-blocking:
// the requesting run keeps going and learns the decision through `session_admin scope_status` /
// `confirmation_status`. Neither card ever passes through the oversight transport.
//
// SEARCH-HELPER: delegate scope approval card, batch confirmation card, session_admin cards.

/// Hosts every pending scope request and batch confirmation for one tab.
struct DelegationApprovalSlot: View {
    let tabID: UUID?
    @ObservedObject var runtime: DelegationScopeRuntime
    @ObservedObject var confirmations: BatchConfirmationCoordinator

    init(tabID: UUID?, runtime: DelegationScopeRuntime) {
        self.tabID = tabID
        self.runtime = runtime
        confirmations = runtime.confirmations
    }

    var body: some View {
        if let tabID {
            let requests = runtime.pendingRequests(forTab: tabID)
            let cards = confirmations.pendingConfirmations(forTab: tabID)
            if !requests.isEmpty || !cards.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(requests) { request in
                        DelegationScopeApprovalCard(
                            request: request,
                            onApprove: { capabilities in
                                _ = runtime.approve(requestID: request.id, capabilities: capabilities)
                            },
                            onDeny: { runtime.deny(requestID: request.id, reason: "Denied by user") }
                        )
                    }
                    ForEach(cards) { card in
                        BatchConfirmationCard(
                            confirmation: card,
                            onToggle: { sessionID, ticked in
                                confirmations.setItem(sessionID, ticked: ticked, confirmationID: card.id)
                            },
                            onApprove: { _ = confirmations.approve(confirmationID: card.id) },
                            onDeny: { confirmations.deny(confirmationID: card.id, reason: "Denied by user") }
                        )
                    }
                }
            }
        }
    }
}

/// One-time approval of a delegation scope requested by an Agent session.
struct DelegationScopeApprovalCard: View {
    let request: DelegationScopeRequest
    let onApprove: (Set<DomainDelegationScopeCapability>) -> Void
    let onDeny: () -> Void

    @State private var selected: Set<DomainDelegationScopeCapability>

    init(
        request: DelegationScopeRequest,
        onApprove: @escaping (Set<DomainDelegationScopeCapability>) -> Void,
        onDeny: @escaping () -> Void
    ) {
        self.request = request
        self.onApprove = onApprove
        self.onDeny = onDeny
        _selected = State(initialValue: request.capabilities)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delegate authority to this session?")
                        .font(.headline)
                    Text(kindDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let reason = request.reason {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent's stated reason (unverified)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Capabilities")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(DomainDelegationScopeCapability.allCases.filter(request.capabilities.contains), id: \.self) { capability in
                    Toggle(isOn: binding(for: capability)) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(capability.rawValue)
                            Text(Self.summary(for: capability))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Text(guardrailSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Deleting sessions, removing worktrees, keys, permission modes, and settings always stay with you.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Deny", action: onDeny)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Grant") { onApprove(selected) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 1)
        )
    }

    private func binding(for capability: DomainDelegationScopeCapability) -> Binding<Bool> {
        Binding(
            get: { selected.contains(capability) },
            set: { isOn in
                if isOn { selected.insert(capability) } else { selected.remove(capability) }
            }
        )
    }

    private var kindDescription: String {
        switch request.kind {
        case .tree: "Scope: this session and the sessions it creates"
        case .workspace: "Scope: every session in one workspace"
        case .allSessions: "Scope: every session you own"
        }
    }

    private var guardrailSummary: String {
        let guardrails = request.guardrails
        var parts: [String] = []
        if let limit = guardrails.maxLiveSessions { parts.append("max \(limit) live sessions") }
        if let limit = guardrails.maxDepth { parts.append("max depth \(limit)") }
        if let limit = guardrails.maxWorktrees { parts.append("max \(limit) worktrees") }
        if let seconds = request.expiresInSeconds {
            let lifetime = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
            parts.append("expires \(lifetime) after you grant it")
        }
        parts.append("bulk changes over \(guardrails.bulkConfirmationThreshold) items ask you first")
        return "Guardrails: " + parts.joined(separator: " · ")
    }

    static func summary(for capability: DomainDelegationScopeCapability) -> String {
        switch capability {
        case .observe: "List, search, and read member sessions"
        case .organize: "Rename, pin, group, archive"
        case .control: "Send, steer, answer prompts, stop, set model"
        case .restructure: "Link, unlink, re-parent, release"
        case .spawn: "Start sessions and nested overseers"
        case .worktree: "Create and bind worktrees, merge preview"
        case .destructive: "Reserved; retire and worktree release always ask you regardless"
        }
    }
}

/// One card listing every item a destructive or large bulk operation would affect.
struct BatchConfirmationCard: View {
    let confirmation: PendingBatchConfirmation
    let onToggle: (UUID, Bool) -> Void
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm \(confirmation.operation.rawValue)")
                        .font(.headline)
                    Text("\(confirmation.approvedSessionIDs.count) of \(confirmation.items.count) selected · \(reasonText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(confirmation.items) { item in
                        Toggle(isOn: Binding(
                            get: { !confirmation.untickedSessionIDs.contains(item.sessionID) },
                            set: { onToggle(item.sessionID, $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title).lineLimit(1)
                                Text(item.effect)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Button("Deny", action: onDeny)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Apply to selected", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .disabled(confirmation.approvedSessionIDs.isEmpty)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.28), lineWidth: 1)
        )
    }

    private var reasonText: String {
        switch confirmation.reason {
        case .destructive: "always confirmed"
        case .adoption: "adds sessions to the scope"
        case .bulkThreshold: "large bulk change"
        }
    }
}
