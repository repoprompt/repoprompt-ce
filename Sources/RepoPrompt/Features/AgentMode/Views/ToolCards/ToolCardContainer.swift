import SwiftUI

/// Shared time formatter for tool cards — avoids repeated DateFormatter allocations.
private let toolCardTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func performAgentToolCardExpansionStateUpdateWithoutAnimation(_ update: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        update()
    }
}

extension EnvironmentValues {
    @Entry var agentToolCardAutoExpandEnabled: Bool = true

    @Entry var agentLiveBashExecutionByItemID: [UUID: AgentModeViewModel.BashLiveExecutionState] = [:]

    @Entry var agentRecentAssistantItemIDs: Set<UUID> = []

    @Entry var agentMessageRuntimeFooterByItemID: [UUID: AgentMessageRuntimeFooter] = [:]

    @Entry var agentApprovalVisible: Bool = false
}

enum AgentToolCardRenderedBashPhase: String, Equatable {
    case live
    case completed
}

enum AgentToolCardRenderMode: String, Equatable {
    case diffPreview
    case toolSpecificNoDiff
    case markdownFallback
}

struct AgentToolCardRenderState: Equatable {
    let itemID: UUID
    let toolName: String
    let isExpanded: Bool
    let bashPhase: AgentToolCardRenderedBashPhase?
    let renderMode: AgentToolCardRenderMode?
}

struct AgentToolCardRenderStatePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: AgentToolCardRenderState] = [:]

    static func reduce(value: inout [UUID: AgentToolCardRenderState], nextValue: () -> [UUID: AgentToolCardRenderState]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Shared container providing consistent UI chrome for all tool cards
/// Supports collapsed (1-line summary) and expanded states via isExpanded binding
struct ToolCardContainer<Content: View>: View {
    let iconName: String
    let iconColor: Color
    let title: String
    let headerStatusText: String?
    let detailText: String?
    let subtitle: String?
    let status: ToolCardStatus
    let timestamp: Date?
    let showsTimestamp: Bool
    let headerTrailingView: AnyView?
    let isExpandable: Bool
    let managesOwnExpansion: Bool
    let debugItemID: UUID?
    let debugToolName: String?
    let debugBashPhase: AgentToolCardRenderedBashPhase?
    let debugRenderMode: AgentToolCardRenderMode?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        iconName: String,
        iconColor: Color = .orange,
        title: String,
        headerStatusText: String? = nil,
        detailText: String? = nil,
        subtitle: String? = nil,
        status: ToolCardStatus = .neutral,
        timestamp: Date? = nil,
        showsTimestamp: Bool = true,
        headerTrailingView: AnyView? = nil,
        isExpandable: Bool = true,
        debugItemID: UUID? = nil,
        debugToolName: String? = nil,
        debugBashPhase: AgentToolCardRenderedBashPhase? = nil,
        debugRenderMode: AgentToolCardRenderMode? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.headerStatusText = headerStatusText
        self.detailText = detailText
        self.subtitle = subtitle
        self.status = status
        self.timestamp = timestamp
        self.showsTimestamp = showsTimestamp
        self.headerTrailingView = headerTrailingView
        self.isExpandable = isExpandable
        managesOwnExpansion = false
        self.debugItemID = debugItemID
        self.debugToolName = debugToolName
        self.debugBashPhase = debugBashPhase
        self.debugRenderMode = debugRenderMode
        _isExpanded = isExpanded
        self.content = content
    }

    init(
        iconName: String,
        iconColor: Color = .orange,
        title: String,
        headerStatusText: String? = nil,
        detailText: String? = nil,
        subtitle: String? = nil,
        status: ToolCardStatus = .neutral,
        timestamp: Date? = nil,
        showsTimestamp: Bool = true,
        headerTrailingView: AnyView? = nil,
        isExpandable: Bool = true,
        managesOwnExpansion: Bool,
        debugItemID: UUID? = nil,
        debugToolName: String? = nil,
        debugBashPhase: AgentToolCardRenderedBashPhase? = nil,
        debugRenderMode: AgentToolCardRenderMode? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.headerStatusText = headerStatusText
        self.detailText = detailText
        self.subtitle = subtitle
        self.status = status
        self.timestamp = timestamp
        self.showsTimestamp = showsTimestamp
        self.headerTrailingView = headerTrailingView
        self.isExpandable = isExpandable
        self.managesOwnExpansion = managesOwnExpansion
        self.debugItemID = debugItemID
        self.debugToolName = debugToolName
        self.debugBashPhase = debugBashPhase
        self.debugRenderMode = debugRenderMode
        _isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        HStack {
            cardBody
            Spacer(minLength: 40)
        }
        .preference(key: AgentToolCardRenderStatePreferenceKey.self, value: debugRenderStatePreference)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            // Header row (always visible - serves as 1-line summary when collapsed)
            // Entire row is clickable to expand/collapse when expandable
            if isExpandable {
                if headerTrailingView == nil {
                    Button(action: toggleExpansion) {
                        headerRow
                    }
                    .buttonStyle(.plain)
                } else {
                    expandableHeaderRowWithTrailingControl
                }
            } else {
                headerRow
            }

            // Content area (only shown when expanded)
            if isExpanded, isExpandable {
                content()
            }
        }
        .padding(10)
        .background(backgroundColor)
        .cornerRadius(12)
        .contentShape(Rectangle())
    }

    private func toggleExpansion() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isExpanded.toggle()
        }
    }

    private var expandableHeaderRowWithTrailingControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(action: toggleExpansion) {
                    headerLeadingContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if let headerTrailingView {
                    headerTrailingView
                } else if showsTimestamp, let timestamp {
                    Text(formattedTime(timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            if let detailText {
                Button(action: toggleExpansion) {
                    headerDetailText(detailText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                headerLeadingContent
                Spacer()

                if let headerTrailingView {
                    headerTrailingView
                } else if showsTimestamp, let timestamp {
                    Text(formattedTime(timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            if let detailText {
                headerDetailText(detailText)
            }
        }
    }

    private var headerLeadingContent: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundColor(iconColor)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            if let headerStatusText, !headerStatusText.isEmpty {
                StatusBadge(text: headerStatusText, status: status)
            } else {
                StatusDot(status: status, size: 6)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func headerDetailText(_ detailText: String) -> some View {
        Text(detailText)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 17)
    }

    private var backgroundColor: Color {
        switch status {
        case .running:
            BubbleColors.toolCallBackground(colorScheme: colorScheme)
        case .failure:
            BubbleColors.errorBackground(colorScheme: colorScheme)
        default:
            BubbleColors.toolResultBackground(colorScheme: colorScheme)
        }
    }

    private func formattedTime(_ date: Date) -> String {
        toolCardTimeFormatter.string(from: date)
    }

    private var debugRenderStatePreference: [UUID: AgentToolCardRenderState] {
        guard let debugItemID,
              let debugToolName,
              !debugToolName.isEmpty
        else {
            return [:]
        }
        return [
            debugItemID: AgentToolCardRenderState(
                itemID: debugItemID,
                toolName: debugToolName,
                isExpanded: isExpanded && isExpandable,
                bashPhase: debugBashPhase,
                renderMode: debugRenderMode
            )
        ]
    }
}

// MARK: - Static Tool Card Container (Non-Expandable)

/// Container for tool cards that don't need expansion (e.g., tool calls in progress)
struct StaticToolCardContainer<Content: View>: View {
    let iconName: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let status: ToolCardStatus
    let timestamp: Date?
    let showsTimestamp: Bool
    let headerTrailingView: AnyView?
    let onTap: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        iconName: String,
        iconColor: Color = .orange,
        title: String,
        subtitle: String? = nil,
        status: ToolCardStatus = .neutral,
        timestamp: Date? = nil,
        showsTimestamp: Bool = true,
        headerTrailingView: AnyView? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.timestamp = timestamp
        self.showsTimestamp = showsTimestamp
        self.headerTrailingView = headerTrailingView
        self.onTap = onTap
        self.content = content
    }

    var body: some View {
        Group {
            if let onTap, headerTrailingView == nil {
                Button(action: onTap) {
                    cardBody
                }
                .buttonStyle(.plain)
            } else if let onTap {
                cardBody
                    .onTapGesture(perform: onTap)
            } else {
                cardBody
            }
        }
    }

    private var cardBody: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                standardHeaderRow
                content()
            }
            .padding(10)
            .background(backgroundColor)
            .cornerRadius(12)
            .contentShape(Rectangle())

            Spacer(minLength: 40)
        }
    }

    private var standardHeaderRow: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundColor(iconColor)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            StatusDot(status: status, size: 6)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let headerTrailingView {
                headerTrailingView
            } else if showsTimestamp, let timestamp {
                Text(formattedTime(timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .running:
            BubbleColors.toolCallBackground(colorScheme: colorScheme)
        case .failure:
            BubbleColors.errorBackground(colorScheme: colorScheme)
        default:
            BubbleColors.toolResultBackground(colorScheme: colorScheme)
        }
    }

    private func formattedTime(_ date: Date) -> String {
        toolCardTimeFormatter.string(from: date)
    }
}

// MARK: - Tool Card Cancel Button

/// Plain cancel button for the far-right header slot of running RepoPrompt MCP tool cards.
struct ToolCardCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Cancel")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Tool Icon Helpers

/// Get appropriate SF Symbol icon for a tool
func toolIcon(for toolName: String?) -> String {
    let normalized = normalizedToolCardName(toolName) ?? toolName
    switch normalized {
    case "ask_user_question", "ask_user", "AskUserQuestion", "request_user_input", "requestUserInput":
        return "questionmark.circle"
    case "read", "Read", "read_file", "mcp__RepoPrompt__read_file":
        return "doc.text"
    case "bash", "shell", "local_shell", "unified_exec", "exec_command", "run_shell_command":
        return "terminal"
    case "search", "web_search", "web_search_request", "google_web_search", "search_web":
        return "globe"
    case "apply_edits", "mcp__RepoPrompt__apply_edits":
        return "pencil"
    case "apply_patch", "edit":
        return "pencil"
    case "file_actions", "mcp__RepoPrompt__file_actions":
        return "doc.badge.plus"
    case "file_search", "mcp__RepoPrompt__file_search":
        return "magnifyingglass.circle"
    case "get_file_tree", "mcp__RepoPrompt__get_file_tree":
        return "folder"
    case "get_code_structure", "mcp__RepoPrompt__get_code_structure":
        return "list.bullet.indent"
    case "manage_selection", "mcp__RepoPrompt__manage_selection":
        return "checkmark.circle"
    case "workspace_context", "mcp__RepoPrompt__workspace_context":
        return "square.stack.3d.up"
    case "ask_oracle", "mcp__RepoPrompt__ask_oracle":
        return "brain"
    case "oracle_send", "mcp__RepoPrompt__oracle_send":
        return "bubble.left.and.bubble.right"
    case "oracle_chat_log", "mcp__RepoPrompt__oracle_chat_log":
        return "clock.arrow.circlepath"
    case "chat_send", "mcp__RepoPrompt__chat_send":
        return "bubble.left.and.bubble.right"
    case "context_builder", "mcp__RepoPrompt__context_builder":
        return "sparkles"
    case "git", "mcp__RepoPrompt__git":
        return "arrow.triangle.branch"
    case "manage_worktree", "mcp__RepoPrompt__manage_worktree":
        return "rectangle.split.3x1"
    case "prompt", "mcp__RepoPrompt__prompt":
        return "text.quote"
    case "chats", "mcp__RepoPrompt__chats":
        return "bubble.left.and.bubble.right"
    case "list_models", "mcp__RepoPrompt__list_models":
        return "cpu"
    case "bind_context", "mcp__RepoPrompt__bind_context":
        return "scope"
    case "manage_workspaces", "mcp__RepoPrompt__manage_workspaces":
        return "rectangle.3.group"
    case "agent_explore", "mcp__RepoPrompt__agent_explore":
        return "magnifyingglass.circle"
    case "agent_run", "mcp__RepoPrompt__agent_run":
        return "play.circle"
    case "agent_manage", "mcp__RepoPrompt__agent_manage":
        return "tray.full"
    case "app_settings", "mcp__RepoPrompt__app_settings":
        return "gearshape.2"
    default:
        return "gearshape.fill"
    }
}

/// Get human-readable display name for a tool
func toolDisplayName(for toolName: String?) -> String {
    guard let nameRaw = toolName else { return "Tool" }
    let name = normalizedToolCardName(nameRaw) ?? nameRaw

    // Strip MCP prefix if present
    let stripped = name.replacingOccurrences(of: "mcp__RepoPrompt__", with: "")

    switch stripped {
    case "ask_user_question", "ask_user", "AskUserQuestion", "request_user_input", "requestUserInput":
        return "Question"
    case "bash", "shell", "local_shell", "unified_exec", "exec_command", "run_shell_command":
        return "Bash"
    case "search", "web_search", "web_search_request", "google_web_search", "search_web":
        return "Web Search"
    case "read", "Read":
        return "Read"
    case "read_file":
        return "Read File"
    case "apply_edits":
        return "Edit"
    case "apply_patch":
        return "Patch"
    case "edit":
        return "Edit File"
    case "file_actions":
        return "File Action"
    case "file_search":
        return "Search"
    case "get_file_tree":
        return "File Tree"
    case "get_code_structure":
        return "Code Structure"
    case "manage_selection":
        return "Selection"
    case "workspace_context":
        return "Context"
    case "ask_oracle":
        return "Oracle"
    case "oracle_send":
        return "Oracle"
    case "oracle_chat_log":
        return "Oracle Log"
    case "chat_send":
        return "Chat"
    case "context_builder":
        return "Context Builder"
    case "git":
        return "Git"
    case "manage_worktree":
        return "Worktrees"
    case "prompt":
        return "Prompt"
    case "chats":
        return "Chats"
    case "list_models":
        return "Models"
    case "bind_context":
        return "Bind Context"
    case "manage_workspaces":
        return "Workspaces"
    case "agent_explore":
        return "Agent Explore"
    case "agent_run":
        return "Agent Run"
    case "agent_manage":
        return "Agent Manage"
    case "app_settings":
        return "App Settings"
    default:
        // Convert snake_case to Title Case
        return stripped
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Path Helpers

/// Shorten a file path for display (show last 2 components)
func shortenPath(_ path: String) -> String {
    let components = path.split(separator: "/")
    if components.count <= 2 {
        return path
    }
    return "…/" + components.suffix(2).joined(separator: "/")
}

/// Extract just the filename from a path
func fileName(from path: String) -> String {
    (path as NSString).lastPathComponent
}

// MARK: - Preview

#if DEBUG
    struct ToolCardContainer_Previews: PreviewProvider {
        static var previews: some View {
            VStack(spacing: 12) {
                PreviewExpandableCard()

                StaticToolCardContainer(
                    iconName: "folder",
                    iconColor: .orange,
                    title: "File Tree",
                    subtitle: "5 roots",
                    status: .success,
                    timestamp: Date()
                ) {
                    EmptyView()
                }

                StaticToolCardContainer(
                    iconName: "magnifyingglass.circle",
                    iconColor: .orange,
                    title: "Search",
                    subtitle: "\"TODO\"",
                    status: .warning,
                    timestamp: Date()
                ) {
                    StatusBadge(text: "Partial", status: .warning)
                }
            }
            .padding()
            .frame(width: 400)
        }
    }

    private struct PreviewExpandableCard: View {
        @State private var isExpanded = false

        var body: some View {
            ToolCardContainer(
                iconName: "doc.text",
                title: "Read File",
                subtitle: "main.swift \u{2022} Lines 1-50 of 200",
                status: .success,
                timestamp: Date(),
                isExpanded: $isExpanded
            ) {
                Text("File content would go here...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
#endif
