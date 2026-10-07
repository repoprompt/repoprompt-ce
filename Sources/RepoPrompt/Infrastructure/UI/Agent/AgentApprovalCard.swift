import SwiftUI

struct AgentApprovalCard: View {
    let request: AgentApprovalRequest
    let onDecision: (_ decision: AgentApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            if request.details.isEmpty {
                Text("No extra details provided.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(request.details) { detail in
                    detailRow(detail)
                }
            }

            actionButtons
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.headline)
                Text("Needs your approval")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(request.method)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func detailRow(_ detail: AgentApprovalDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.label)
                .font(.caption)
                .foregroundColor(.secondary)
            if detail.isCode {
                Text(detail.value)
                    .font(.caption.monospaced())
                    .foregroundColor(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
            } else {
                Text(detail.value)
                    .font(.callout)
                    .foregroundColor(.primary)
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button(action: { onDecision(.decline) }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    Text("Decline")
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            if request.supportsAlwaysAllow {
                Button(action: alwaysAllowDecision) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                        Text(alwaysAllowLabel)
                    }
                }
                .buttonStyle(.bordered)
            }

            Button(action: { onDecision(.accept) }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Approve")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!request.supportsPlainApprove)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var alwaysAllowLabel: String {
        if request.proposedExecpolicyAmendmentJSON != nil {
            return "Approve & Remember"
        }
        return request.sessionApprovalLabel
    }

    private func alwaysAllowDecision() {
        if let amendment = request.proposedExecpolicyAmendmentJSON, !amendment.isEmpty {
            onDecision(.acceptWithExecpolicyAmendment(amendment))
        } else {
            onDecision(.acceptForSession)
        }
    }
}

struct AgentMCPElicitationCard: View {
    let request: AgentMCPElicitationRequest
    let onResponse: (_ response: AgentMCPElicitationResponse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            if let prompt = (request.prompt ?? request.message), !prompt.isEmpty {
                Text(prompt)
                    .font(.callout)
                    .foregroundColor(.primary)
            }
            if request.details.isEmpty {
                Text("No extra details provided.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(request.details) { detail in
                    detailRow(detail)
                }
            }
            actionButtons
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.title2)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.headline)
                Text("MCP elicitation needs your response")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(request.serverName ?? request.method)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func detailRow(_ detail: AgentApprovalDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.label)
                .font(.caption)
                .foregroundColor(.secondary)
            if detail.isCode {
                Text(detail.value)
                    .font(.caption.monospaced())
                    .foregroundColor(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
            } else {
                Text(detail.value)
                    .font(.callout)
                    .foregroundColor(.primary)
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button(action: { onResponse(.init(action: .decline)) }) {
                Label("Decline", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            Button(role: .destructive, action: { onResponse(.init(action: .cancel)) }) {
                Label("Cancel Run", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            Spacer()
            Button(action: { onResponse(.init(action: .accept)) }) {
                Label("Accept", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}

#if DEBUG
    struct AgentApprovalCard_Previews: PreviewProvider {
        static var previews: some View {
            AgentApprovalCard(
                request: AgentApprovalRequest(
                    requestID: .codex(.int(1)),
                    method: "item/commandExecution/requestApproval",
                    kind: .commandExecution,
                    threadID: "thread-1",
                    turnID: "turn-1",
                    itemID: "item-1",
                    reason: "Command requires full access",
                    command: "rm -rf /",
                    cwd: "/Users/demo",
                    details: [
                        AgentApprovalDetail(label: "Reason", value: "Command requires full access"),
                        AgentApprovalDetail(label: "Command", value: "rm -rf /", isCode: true)
                    ]
                ),
                onDecision: { _ in }
            )
            .padding()
            .previewLayout(.sizeThatFits)
        }
    }
#endif
