import SwiftUI

struct MCPToolsSettingsView: View {
    @ObservedObject var server: MCPServerViewModel
    @ObservedObject private var toolStore = ToolAvailabilityStore.shared
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var windowToolsEnabledBinding: Binding<Bool> {
        Binding(
            get: { server.windowToolsEnabled },
            set: { enabled in
                Task { @MainActor [weak server] in
                    _ = await server?.setWindowToolsEnabled(enabled)
                }
            }
        )
    }

    @State private var searchText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                controlsSection
                toolsListSection
            }
            .padding()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("MCP Tools")
                    .font(.title2.weight(.semibold))
            }

            Text("Enable or disable individual MCP tools for this window.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable MCP tools for this window", isOn: windowToolsEnabledBinding)
                .hoverTooltip("Allow external tools to interact with this window's workspace")
                .accessibilityHint("Allow external tools to interact with this window's workspace")

            if !server.windowToolsEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("Tools are disabled for this window. Enable MCP tools to update availability.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            }

            Text(enabledSummaryText)
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)

            searchField
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    private var toolsListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tool Availability")
                    .font(.headline)
                Spacer()
                if !toolStore.advertisedToolSummaries.isEmpty {
                    Text(filteredSummaryText)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                }
            }

            if toolStore.advertisedToolSummaries.isEmpty {
                emptyStateView
            } else if filteredSummaries.isEmpty {
                Text("No tools match your search.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredSummaries) { summary in
                        ToolRow(
                            name: summary.name,
                            description: summary.description,
                            fontPreset: fontPreset,
                            getIsOn: { toolStore.isEnabled(summary.name) },
                            setIsOn: { enabled in
                                Task { await toolStore.toggle(summary.name, enabled: enabled) }
                            },
                            disabled: !server.windowToolsEnabled
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No tools discovered")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
            Text("Start the MCP server and connect a client to populate tool availability.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("Search tools...", text: $searchText)
                .textFieldStyle(PlainTextFieldStyle())
                .font(fontPreset.font)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var filteredSummaries: [ToolAvailabilityStore.ToolSummary] {
        let summaries = toolStore.advertisedToolSummaries
        guard !searchText.isEmpty else { return summaries }
        let needle = searchText.lowercased()
        return summaries.filter { summary in
            summary.name.lowercased().contains(needle)
                || summary.description.lowercased().contains(needle)
        }
    }

    private var enabledCount: Int {
        toolStore.advertisedToolSummaries.count(where: { toolStore.isEnabled($0.name) })
    }

    private var enabledSummaryText: String {
        let total = toolStore.advertisedToolSummaries.count
        guard total > 0 else { return "No tools available yet" }
        return "\(enabledCount) of \(total) tools enabled"
    }

    private var filteredSummaryText: String {
        let total = filteredSummaries.count
        guard !searchText.isEmpty else { return "\(total) tools" }
        let enabled = filteredSummaries.count(where: { toolStore.isEnabled($0.name) })
        return "\(enabled) of \(total) shown enabled"
    }

    private struct ToolRow: View {
        let name: String
        let description: String
        let fontPreset: FontScalePreset
        let getIsOn: () -> Bool
        let setIsOn: (Bool) -> Void
        let disabled: Bool
        @State private var expanded = false
        private let truncationThreshold = 160

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { getIsOn() },
                    set: { setIsOn($0) }
                )) {
                    Text(name)
                        .font(fontPreset.font)
                }
                .disabled(disabled)

                if !description.isEmpty {
                    Text(description)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(expanded ? nil : 3)
                        .truncationMode(.tail)

                    if shouldShowExpander {
                        Button(expanded ? "Show less" : "More...") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expanded.toggle()
                            }
                        }
                        .buttonStyle(.link)
                        .font(fontPreset.captionFont)
                    }
                }
            }
            .padding(.vertical, 4)
        }

        private var shouldShowExpander: Bool {
            description.count > truncationThreshold || expanded
        }
    }
}
