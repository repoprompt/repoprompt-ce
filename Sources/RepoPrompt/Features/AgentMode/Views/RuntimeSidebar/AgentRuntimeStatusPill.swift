import SwiftUI

/// Floating status pill in top-right of agent chat transcript.
/// Shows file context when idle, spinner when context builder or oracle is active.
/// Tapping opens the runtime sidebar.
struct AgentRuntimeStatusPill: View {
    @ObservedObject var contextBuilderAgentVM: ContextBuilderAgentViewModel
    @ObservedObject var oracleViewModel: OracleViewModel
    @ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
    let currentTabID: UUID?
    let onTap: () -> Void

    @State private var isHovered = false

    private var isContextBuilderRunning: Bool {
        guard let tabID = currentTabID else { return false }
        return contextBuilderAgentVM.tabsWithActiveContextBuilderRun.contains(tabID)
    }

    private var isOracleStreaming: Bool {
        guard let tabID = currentTabID else { return false }
        let tabSessions = oracleViewModel.sessions(forTabID: tabID)
        let tabSessionIDs = Set(tabSessions.map(\.id))
        guard !tabSessionIDs.isEmpty else { return false }
        return !oracleViewModel.streamingSessions.isDisjoint(with: tabSessionIDs)
    }

    private enum PillMode: Hashable {
        case contextBuilder
        case oracle
        case idle
    }

    private var mode: PillMode {
        if isContextBuilderRunning {
            return .contextBuilder
        }
        if isOracleStreaming {
            return .oracle
        }
        return .idle
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                pillContent
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(pillBorderColor, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 6 : 3, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.25), value: mode)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch mode {
        case .contextBuilder:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
            Text("Context Builder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

        case .oracle:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
            Text("Oracle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

        case .idle:
            let fileCount = runtimeVM.snapshot.selectionFileCount ?? 0
            let tokens = runtimeVM.snapshot.selectionTokens

            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if let tokens {
                Text("\(fileCount) files · \(AgentContextIndicator.formatTokens(tokens))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if fileCount > 0 {
                Text("\(fileCount) files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pillBorderColor: Color {
        switch mode {
        case .contextBuilder: Color.blue.opacity(0.3)
        case .oracle: Color.purple.opacity(0.3)
        case .idle: Color.secondary.opacity(isHovered ? 0.3 : 0.15)
        }
    }
}
