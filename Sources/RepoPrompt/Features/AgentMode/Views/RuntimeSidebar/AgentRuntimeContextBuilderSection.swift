import SwiftUI

struct AgentRuntimeContextBuilderSection: View {
    @ObservedObject var contextBuilderAgentVM: ContextBuilderAgentViewModel
    let currentTabID: UUID?

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    @AppStorage("agent.runtime.sidebar.builder.expanded")
    private var isExpanded: Bool = true

    private var isRunningForTab: Bool {
        guard let currentTabID else { return false }
        return contextBuilderAgentVM.tabsWithActiveContextBuilderRun.contains(currentTabID)
    }

    private var subtitle: String {
        isRunningForTab ? "Running" : "Idle"
    }

    var body: some View {
        AgentRuntimeSectionCard(
            title: "Context Builder Agent",
            subtitle: subtitle,
            trailing: {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        ) {
            if isExpanded {
                if !contextBuilderAgentVM.agentLog.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(contextBuilderAgentVM.agentLog.suffix(5))) { entry in
                            AgentLogEntryRowView(entry: entry, style: .compact)
                        }
                    }
                    if contextBuilderAgentVM.toolCallCount > 0 {
                        Text("\(contextBuilderAgentVM.toolCallCount) tool calls")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                } else {
                    Text("No recent discovery activity for this tab.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .environment(\.showDatesInMessageTimestamps, globalSettings.showDatesInMessageTimestamps())
    }
}
