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

    @State private var refreshTrigger = UUID()
    @State private var isImportingClassicRepoPrompt = false
    @State private var classicRepoPromptImportResultMessage: String?
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
        .id(refreshTrigger)
        .onReceive(NotificationCenter.default.publisher(for: .workspaceListDidChange).receive(on: RunLoop.main)) { _ in
            refreshTrigger = UUID()
        }
        .alert(
            "Classic RepoPrompt Import",
            isPresented: Binding(
                get: { classicRepoPromptImportResultMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        classicRepoPromptImportResultMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                classicRepoPromptImportResultMessage = nil
            }
        } message: {
            Text(classicRepoPromptImportResultMessage ?? "")
        }
    }

    // MARK: - Compact Layout (unchanged)

    private var compactContent: some View {
        VStack(spacing: 16) {
            headerBlock(centered: true)

            openFolderButton

            classicRepoPromptImportButton

            Divider().padding(.vertical, 4)

            recentWorkspacesSection

            if let footer {
                footer
            }
        }
    }

    // MARK: - Expanded Stacked Layout

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 32) {
            // Top: New workspace section
            newWorkspaceSection

            // Bottom: Recent workspaces in two columns
            if !userWorkspaces.isEmpty {
                recentWorkspacesGrid
            }

            if let footer {
                footer
            }
        }
        .frame(maxWidth: maxWidth, alignment: .center)
    }

    private var newWorkspaceSection: some View {
        ZStack(alignment: .topTrailing) {
            // Main content: left side + right links
            HStack(alignment: .top, spacing: 32) {
                // Left: Welcome + Open Folder
                VStack(alignment: .leading, spacing: 12) {
                    Text(effectiveGreetingText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("Open a folder to create a new workspace")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    Button(action: onSelectFolder) {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 16))
                            Text("Open Folder")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(CustomButtonStyle())

                    classicRepoPromptImportButton
                }

                Spacer()

                // Right: Helpful links (with top padding to clear version)
                VStack(alignment: .trailing, spacing: 8) {
                    if let onSetupGuide {
                        HelpLinkButton(title: "Setup Guide", icon: "sparkles", action: onSetupGuide)
                    }
                    helpLink(title: "Documentation", icon: "book", url: "https://repoprompt.com/docs")
                    helpLink(title: "Discord", icon: "bubble.left.and.bubble.right", url: "https://discord.gg/NtbFDAJPGM")
                    helpLink(title: "Changelog", icon: "list.bullet.rectangle", url: "https://repoprompt.com/docs#s=changelog")
                }
                .padding(.top, 20)
            }
            .padding(20)

            // Version number overlay
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func helpLink(title: String, icon: String, url: String) -> some View {
        HelpLinkButton(title: title, icon: icon) {
            if let linkURL = URL(string: url) {
                NSWorkspace.shared.open(linkURL)
            }
        }
    }

    private var recentWorkspacesGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Recent Workspaces")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)

                ManageButton(action: onManageWorkspaces)

                Spacer(minLength: 12)

                restoreWorkspacesChip
            }

            // Two-column grid
            let columns = [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(userWorkspaces.prefix(maxRecent)) { ws in
                    workspaceCard(ws)
                }
            }
        }
    }

    private var restoreWorkspacesChip: some View {
        Toggle(isOn: $windowStatesManager.autoRestoreWorkspacesEnabled) {
            HStack(spacing: 8) {
                Image(systemName: windowStatesManager.autoRestoreWorkspacesEnabled ? "sparkles.rectangle.stack.fill" : "rectangle.stack.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)

                Text("Auto restore on app launch")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
        .padding(.vertical, 8)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(windowStatesManager.autoRestoreWorkspacesEnabled ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(windowStatesManager.autoRestoreWorkspacesEnabled ? 0.20 : 0.10), lineWidth: 1)
        )
        .hoverTooltip("Reopen the workspace windows that were open the last time RepoPrompt quit.", .top)
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
    private var classicRepoPromptImportButton: some View {
        if ClassicRepoPromptImportService().defaultClassicSourceExists() {
            Button {
                runClassicRepoPromptImport()
            } label: {
                HStack(spacing: 8) {
                    if isImportingClassicRepoPrompt {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(isImportingClassicRepoPrompt ? "Importing Classic..." : "Import Classic RepoPrompt")
                        .font(fontPreset.subheadlineFont)
                }
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 6, horizontalPadding: 12, height: fontPreset.scaledMetric(32)))
            .disabled(isImportingClassicRepoPrompt)
            .hoverTooltip("Import Classic workspaces, sessions, settings, presets, prompts, models, workflows, and CLI/provider settings.", .top)
        }
    }

    private func runClassicRepoPromptImport() {
        guard !isImportingClassicRepoPrompt else { return }
        isImportingClassicRepoPrompt = true

        Task { @MainActor in
            let result = await workspaceManager.importClassicRepoPromptData()
            isImportingClassicRepoPrompt = false
            classicRepoPromptImportResultMessage = result.userFacingSummary()
        }
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
