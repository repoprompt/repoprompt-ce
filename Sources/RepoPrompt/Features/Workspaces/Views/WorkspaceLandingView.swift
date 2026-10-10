import RepoPromptFileSystem
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

    // MARK: - Compact Layout

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
                    Label("Open Folder…", systemImage: "folder")
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
                WorkspaceChooserResultsView(
                    workspaceManager: workspaceManager,
                    query: .expanded(collection: showTemporaryWorkspaces ? .temporary : .saved, searchText: searchText),
                    onOpenWorkspace: onOpenWorkspace
                )
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

    private var effectiveGreetingText: String {
        greetingText ?? "Welcome back"
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
            Text("Open a folder to open a workspace.")
                .font(fontPreset.font)
                .foregroundColor(.secondary)
                .multilineTextAlignment(centered ? .center : .leading)
        }
    }

    private var openFolderButton: some View {
        Button(action: onSelectFolder) {
            HStack {
                Image(systemName: "folder")
                Text("Open Folder")
                    .font(fontPreset.font)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .buttonStyle(CustomButtonStyle())
        .hoverTooltip("Open a folder or reopen a matching workspace", .top)
    }

    @ViewBuilder
    private var recentWorkspacesSection: some View {
        WorkspaceChooserResultsView(
            workspaceManager: workspaceManager, query: .compact(maxRecent: maxRecent), onOpenWorkspace: onOpenWorkspace
        )

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

/// Both Landing layouts consume one captured presentation and one production query.
struct WorkspaceChooserResultsView: View {
    @ObservedObject var workspaceManager: WorkspaceManagerViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared
    let query: WorkspaceChooserQuery
    let onOpenWorkspace: (WorkspaceModel) -> Void

    var body: some View {
        let captured = workspaceManager.workspaceChooserPresentation
        let presentation = query.applying(to: captured)
        switch presentation {
        case .loading:
            let _ = report(kind: .loading, rows: [], source: nil, failure: nil)
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading workspaces…")
            }
            .foregroundStyle(.secondary)
        case let .failed(failure):
            let _ = report(kind: .failed, rows: [], source: nil, failure: failure)
            VStack(spacing: 8) {
                Text("Unable to load workspaces.")
                Text("Try again, or open a folder.").foregroundStyle(.secondary)
                retryButton(failure)
            }
        case let .ready(catalog, refresh):
            let failure = presentation.failure
            let _ = report(kind: .ready, rows: catalog.workspaces, source: catalog.source, failure: failure)
            VStack(alignment: .leading, spacing: 8) {
                if case let .failed(failure) = refresh {
                    HStack {
                        Text(warning(for: catalog.source)).font(.callout).foregroundStyle(.secondary)
                        retryButton(failure)
                    }
                }
                if catalog.workspaces.isEmpty {
                    emptyResults(source: catalog.source, hasFailure: failure != nil)
                } else {
                    switch query {
                    case .compact:
                        Text("Recent workspaces")
                            .font(fontScale.preset.subheadlineFont)
                            .foregroundStyle(.secondary)
                        ForEach(catalog.workspaces) { workspace in
                            Button(action: { onOpenWorkspace(workspace) }) {
                                Text(workspace.name).font(fontScale.preset.font)
                            }
                            .buttonStyle(LinkButtonStyle())
                        }
                    case .expanded:
                        LazyVStack(spacing: 6) {
                            ForEach(catalog.workspaces) { workspace in
                                WorkspaceCardButton(ws: workspace, abbreviatePath: abbreviatePath) {
                                    onOpenWorkspace(workspace)
                                }
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
                        }
                    }
                }
            }
        }
    }

    private func retryButton(_ failure: WorkspaceChooserFailure) -> some View {
        Button(action: workspaceManager.retryWorkspaceChooser) {
            HStack {
                if failure.recovery.isRetrying { ProgressView().controlSize(.small) }
                Text(failure.recovery.isRetrying ? "Retrying…" : "Retry")
            }
        }
        .disabled(failure.recovery.isRetrying)
    }

    private func warning(for source: WorkspaceChooserCatalog.Source) -> String {
        if case let .authority(stamp) = source, !stamp.isComplete {
            return "Some workspaces are unavailable. Showing available workspaces."
        }
        return "Workspaces couldn’t be refreshed. Showing the last available list."
    }

    @ViewBuilder
    private func emptyResults(source: WorkspaceChooserCatalog.Source, hasFailure: Bool) -> some View {
        switch query {
        case .compact:
            let unavailableText = if case let .authority(stamp) = source, !stamp.isComplete {
                "No workspaces available in this incomplete list"
            } else {
                "No workspaces available in the last loaded list"
            }
            Text(hasFailure ? unavailableText : "No existing workspaces")
                .font(fontScale.preset.font)
                .foregroundStyle(.secondary)
        case .expanded:
            let searching = !query.rawSearchText.isEmpty
            let collection = query.collection == .temporary ? "temporary" : "saved"
            VStack(spacing: 8) {
                Image(systemName: searching ? "magnifyingglass" : "folder").font(.title)
                Text(
                    searching
                        ? (hasFailure ? "No available matching workspaces" : "No matching workspaces")
                        : (hasFailure ? "No available \(collection) workspaces" : "No \(collection) workspaces")
                )
                Text(searching ? "Try another name or folder path." : "Open a folder to get started.").font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private enum BranchKind { case loading, failed, ready }

    private func report(
        kind: BranchKind, rows: [WorkspaceModel], source: WorkspaceChooserCatalog.Source?, failure: WorkspaceChooserFailure?
    ) {
        #if DEBUG
            let observedKind: WorkspaceChooserConsumption.Kind = switch kind {
            case .loading: .loading
            case .failed: .failed
            case .ready: .ready
            }
            workspaceManager.didConsumeWorkspaceChooserForTesting(.init(
                kind: observedKind, orderedIDs: rows.map(\.id), query: query, source: source, failure: failure
            ))
        #endif
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
