import SwiftUI

struct WorkspaceLandingView: View {
    enum LayoutStyle {
        case compact
        case expanded
    }

    @ObservedObject var workspaceManager: WorkspaceManagerViewModel
    let onOpenWorkspace: (WorkspaceModel) -> Void
    let onManageWorkspaces: () -> Void
    let onSelectFolder: () -> Void

    var maxRecent: Int = 5
    var maxWidth: CGFloat = 300
    var topPadding: CGFloat = 16
    var horizontalPadding: CGFloat = 16
    var layoutStyle: LayoutStyle = .compact
    var greetingText: String?
    var footer: AnyView?
    var onSetupGuide: (() -> Void)?

    @State private var searchText = ""
    @State private var showTemporaryWorkspaces = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    @ObservedObject private var windowStatesManager = WindowStatesManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        Group {
            switch layoutStyle {
            case .compact:
                compactContent
            case .expanded:
                expandedContent
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: layoutStyle == .expanded ? .center : .top)
        .padding(.top, topPadding)
        .padding(.horizontal, horizontalPadding)
    }

    // MARK: - Compact Layout (unchanged)

    private var compactContent: some View {
        VStack(spacing: 16) {
            headerBlock(centered: true)

            openFolderButton

            Divider().padding(.vertical, 4)

            recentWorkspacesSection

            if let footer {
                footer
            }
        }
    }

    // MARK: - Expanded Stacked Layout

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Workspaces")
                        .font(.system(size: 25, weight: .semibold))
                    Text("Choose a project to continue, or open a folder.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onSelectFolder) {
                    Label("Open Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(CustomButtonStyle())
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by name or folder", text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search workspaces")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear workspace search")
                    }
                }
                .padding(9)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))

                Picker("Workspace collection", selection: $showTemporaryWorkspaces) {
                    Text("Saved").tag(false)
                    Text("Temporary").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                ManageButton(action: onManageWorkspaces)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredWorkspaces) { workspace in
                        workspaceCard(workspace)
                            .contextMenu {
                                if !workspace.isEphemeral {
                                    Button(workspace.isTemporaryWorkspace ? "Keep in Saved Workspaces" : "Move to Temporary Workspaces") {
                                        Task {
                                            await workspaceManager.setWorkspaceLibraryMembership(workspace, saved: workspace.isTemporaryWorkspace)
                                        }
                                    }
                                }
                            }
                    }
                    if filteredWorkspaces.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: searchText.isEmpty ? "folder" : "magnifyingglass")
                                .font(.title)
                            Text(searchText.isEmpty ? "No \(showTemporaryWorkspaces ? "temporary" : "saved") workspaces" : "No matching workspaces")
                            Text(searchText.isEmpty ? "Open a folder to get started." : "Try another name or folder path.")
                                .font(.callout)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
            }
            .frame(minHeight: 180, idealHeight: 350, maxHeight: 440)

            Divider()
            HStack {
                Toggle("Restore windows on launch", isOn: $windowStatesManager.autoRestoreWorkspacesEnabled)
                    .toggleStyle(.checkbox)
                Spacer()
                if let onSetupGuide {
                    Button("Setup Guide", action: onSetupGuide).buttonStyle(.link)
                }
                Link("Documentation", destination: URL(string: "https://repoprompt.com/docs")!)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let footer { footer }
        }
        .frame(maxWidth: maxWidth)
    }

    private var filteredWorkspaces: [WorkspaceModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspaceManager.workspacesForMenu(.init(includeTemporary: true)).filter {
            $0.isTemporaryWorkspace == showTemporaryWorkspaces
                && (
                    query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                        || $0.repoPaths.contains { $0.localizedCaseInsensitiveContains(query) }
                )
        }
    }

    private func workspaceCard(_ ws: WorkspaceModel) -> some View {
        WorkspaceCardButton(ws: ws, abbreviatePath: abbreviatePath) {
            onOpenWorkspace(ws)
        }
    }

    private var effectiveGreetingText: String {
        greetingText ?? "Welcome back"
    }

    private func abbreviatePath(_ path: String) -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(homeDir) {
            return "~" + path.dropFirst(homeDir.count)
        }
        return path
    }

    // MARK: - Legacy Helpers (for compact mode)

    private func headerBlock(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            if let greetingText {
                Text(greetingText)
                    .font(fontPreset.titleFont)
            }
            Text("Workspaces")
                .font(fontPreset.headlineFont)
            Text("Open or drag a folder to create a new workspace.")
                .font(fontPreset.font)
                .foregroundColor(.secondary)
                .multilineTextAlignment(centered ? .center : .leading)
        }
    }

    private var openFolderButton: some View {
        Button(action: onSelectFolder) {
            HStack {
                Image(systemName: "folder.badge.plus")
                Text("Open Folder")
                    .font(fontPreset.font)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .buttonStyle(CustomButtonStyle())
        .hoverTooltip("Open a folder and create a new workspace", .top)
    }

    @ViewBuilder
    private var recentWorkspacesSection: some View {
        if userWorkspaces.isEmpty {
            Text("No existing workspaces")
                .font(fontPreset.font)
                .foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent workspaces")
                    .font(fontPreset.subheadlineFont)
                    .foregroundColor(.secondary)

                ForEach(userWorkspaces.prefix(maxRecent)) { ws in
                    Button(action: { onOpenWorkspace(ws) }) {
                        Text(ws.name)
                            .font(fontPreset.font)
                    }
                    .buttonStyle(LinkButtonStyle())
                }
            }
        }

        Divider()
            .padding(.vertical, 6)

        Button(action: onManageWorkspaces) {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(fontPreset.captionFont)
                Text("Manage Workspaces...")
                    .font(fontPreset.subheadlineFont)
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(PlainButtonStyle())
        .hoverEffect()
        .hoverTooltip("Edit, rename, or delete workspaces", .top)
    }

    private var userWorkspaces: [WorkspaceModel] {
        workspaceManager.workspacesForMenu()
    }
}

// MARK: - Help Link Button (underline on hover)

private struct HelpLinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12))
                    .underline(isHovering)
            }
            .foregroundColor(.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering = $0 }
    }
}

private struct ManageButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                Text("Manage")
                    .font(.system(size: 12))
            }
            .foregroundColor(isHovering ? .primary : .secondary)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering = $0 }
    }
}

private struct WorkspaceCardButton: View {
    let ws: WorkspaceModel
    let abbreviatePath: (String) -> String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor.opacity(0.8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let path = ws.repoPaths.first {
                        Text(abbreviatePath(path))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(isHovering ? 0.5 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovering = $0 }
    }
}
