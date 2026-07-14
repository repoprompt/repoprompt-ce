import SwiftUI

struct AgentContextDrawerPromptTab: View {
    @ObservedObject var promptManager: PromptViewModel
    @ObservedObject var modelCoordinator: AgentSelectedFilesModelCoordinator
    let exportContext: AgentContextExportViewContext
    let isSwitchBlankingSelectedFiles: Bool

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var copyStatus: CopyStatus = .idle
    @State private var showCopyPresetPopover = false
    @State private var showFileTreePopover = false
    @State private var showCodeMapPopover = false
    @State private var showGitPopover = false
    @State private var showPromptsPopover = false

    private enum CopyStatus: Equatable {
        case idle
        case copying
        case copied
    }

    struct PresetOption: Identifiable {
        let id: UUID
        let label: String
        let icon: String
        let description: String
    }

    struct RenderState {
        let presetOptions: [PresetOption]
        let selectedOption: PresetOption
        let resolvedConfig: PromptContextResolved
        let isManualPreset: Bool
        let selectedPromptIDs: Set<UUID>
        let selectedPrompts: [PromptViewModel.StoredPrompt]

        var selectedPresetID: UUID {
            selectedOption.id
        }
    }

    private struct PresetPresentation {
        let id: UUID
        let label: String
        let icon: String
    }

    private static let basePresetPresentations = [
        PresetPresentation(id: BuiltInCopyPresets.standard.id, label: "Standard", icon: "doc.text"),
        PresetPresentation(id: BuiltInCopyPresets.plan.id, label: "Plan · Architect", icon: "building.columns"),
        PresetPresentation(id: BuiltInCopyPresets.codeReview.id, label: "Review", icon: "checklist"),
        PresetPresentation(id: BuiltInCopyPresets.manual.id, label: "Manual", icon: "slider.horizontal.3")
    ]

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        let state = makeRenderState()

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                AgentContextPromptInstructionsEditor(
                    text: $promptManager.promptText,
                    fontPreset: fontPreset
                )

                composeControlsSection(state)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            refreshIfNeeded()
        }
        .onDisappear {
            if !isSwitchBlankingSelectedFiles {
                modelCoordinator.cancelLoading(keepLoadedModel: true)
            }
        }
        .onReceive(exportContext.selectionChangesPublisher) { change in
            guard !isSwitchBlankingSelectedFiles else { return }
            guard !exportContext.promptManager.isSwitchingComposeTab else { return }
            handleSelectionChange(change, isVisible: true)
        }
        .onChange(of: exportContext.modelRequestIdentity) { _, _ in
            guard !isSwitchBlankingSelectedFiles else { return }
            guard !exportContext.promptManager.isSwitchingComposeTab else { return }
            resetOrRefresh(isVisible: true)
        }
        .onChange(of: state.selectedPresetID) { _, _ in
            guard !isSwitchBlankingSelectedFiles else { return }
            guard !exportContext.promptManager.isSwitchingComposeTab else { return }
            copyStatus = .idle
            refreshIfNeeded()
        }
    }

    private func refreshIfNeeded(force: Bool = false, preserveDisplayedModel: Bool = false) {
        guard !isSwitchBlankingSelectedFiles else { return }
        guard !exportContext.promptManager.isSwitchingComposeTab else { return }
        modelCoordinator.refreshIfNeeded(
            exportContext.makeModelRequest(flushPendingUI: true),
            force: force,
            preserveDisplayedModel: preserveDisplayedModel
        )
    }

    private func resetOrRefresh(isVisible: Bool) {
        guard !isSwitchBlankingSelectedFiles else { return }
        guard !exportContext.promptManager.isSwitchingComposeTab else { return }
        modelCoordinator.invalidate()
        if isVisible {
            refreshIfNeeded()
        }
    }

    private func handleSelectionChange(_ change: WorkspaceSelectionCoordinator.Change, isVisible: Bool) {
        guard exportContext.tabMatchesSelectionChange(change) else { return }
        if isVisible {
            refreshIfNeeded(force: true, preserveDisplayedModel: true)
        } else {
            modelCoordinator.invalidate()
        }
    }

    func makeRenderState() -> RenderState {
        let currentPreset = promptManager.currentCopyPreset()
        let presetOptions = makePresetOptions(currentPreset: currentPreset)
        let selectedOption = presetOptions.first { $0.id == currentPreset.id }!
        let isManualPreset = currentPreset.builtInKind == .manual
        let resolvedConfig = promptManager.resolvePromptContext()
        let selectedPromptIDs = if isManualPreset {
            promptManager.promptSelection(for: .copy)
        } else {
            Set(resolvedConfig.storedPromptIds ?? currentPreset.storedPromptIds ?? [])
        }
        let selectedPrompts = promptManager.storedPrompts.filter { selectedPromptIDs.contains($0.id) }

        return RenderState(
            presetOptions: presetOptions,
            selectedOption: selectedOption,
            resolvedConfig: resolvedConfig,
            isManualPreset: isManualPreset,
            selectedPromptIDs: selectedPromptIDs,
            selectedPrompts: selectedPrompts
        )
    }

    private func makePresetOptions(currentPreset: CopyPreset) -> [PresetOption] {
        let presetManager = CopyPresetManager.shared
        var options = Self.basePresetPresentations.map { presentation in
            let preset = presetManager.preset(with: presentation.id)!
            return PresetOption(
                id: preset.id,
                label: presentation.label,
                icon: presentation.icon,
                description: preset.description ?? copyPresetFallbackDescription(preset)
            )
        }
        if !options.contains(where: { $0.id == currentPreset.id }) {
            options.append(
                PresetOption(
                    id: currentPreset.id,
                    label: currentPreset.name,
                    icon: "doc.text",
                    description: currentPreset.description ?? copyPresetFallbackDescription(currentPreset)
                )
            )
        }
        return options
    }

    private func composeControlsSection(_ state: RenderState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: 8, alignment: .topLeading)],
                alignment: .leading,
                spacing: 8
            ) {
                copyPresetButton(state)
                promptsButton(state)
                fileTreeButton(state)
                codeMapButton(state)
                gitButton(state)
                copyButtonGridCell(state)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 0.5)
        )
    }

    private func copyPresetButton(_ state: RenderState) -> some View {
        Button {
            showCopyPresetPopover.toggle()
        } label: {
            AgentContextDrawerControlLabel(
                title: "Copy Preset",
                value: state.selectedOption.label,
                icon: state.selectedOption.icon,
                tint: .accentColor,
                fontPreset: fontPreset
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCopyPresetPopover, arrowEdge: .bottom) {
            copyPresetPopover(state)
        }
        .hoverTooltip("Choose clipboard packaging preset")
    }

    private func promptsButton(_ state: RenderState) -> some View {
        Button {
            showPromptsPopover.toggle()
        } label: {
            AgentContextDrawerControlLabel(
                title: "Prompts",
                value: promptSummaryText(state),
                icon: "text.quote",
                tint: .teal,
                fontPreset: fontPreset
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPromptsPopover, arrowEdge: .bottom) {
            promptsPopover(state)
        }
        .hoverTooltip(state.isManualPreset ? "Choose stored prompts" : "View preset-supplied prompts")
    }

    private func fileTreeButton(_ state: RenderState) -> some View {
        Button {
            showFileTreePopover.toggle()
        } label: {
            AgentContextDrawerControlLabel(
                title: "File Tree",
                value: fileTreeLabel(state.resolvedConfig.effectiveFileTreeMode),
                icon: fileTreeIcon(state.resolvedConfig.effectiveFileTreeMode),
                tint: .purple,
                fontPreset: fontPreset
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFileTreePopover, arrowEdge: .bottom) {
            fileTreePopover(state)
        }
        .hoverTooltip(state.resolvedConfig.effectiveFileTreeMode.caption)
    }

    private func codeMapButton(_ state: RenderState) -> some View {
        Button {
            showCodeMapPopover.toggle()
        } label: {
            AgentContextDrawerControlLabel(
                title: "Code Map",
                value: codeMapLabel(state.resolvedConfig.codeMapUsage),
                icon: codeMapIcon(state.resolvedConfig.codeMapUsage),
                tint: .indigo,
                fontPreset: fontPreset
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCodeMapPopover, arrowEdge: .bottom) {
            codeMapPopover(state)
        }
        .hoverTooltip(state.resolvedConfig.codeMapUsage.caption)
    }

    private func gitButton(_ state: RenderState) -> some View {
        Button {
            showGitPopover.toggle()
        } label: {
            AgentContextDrawerControlLabel(
                title: "Git",
                value: gitLabel(state.resolvedConfig.gitInclusion),
                icon: gitIcon(state.resolvedConfig.gitInclusion),
                tint: .orange,
                fontPreset: fontPreset
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showGitPopover, arrowEdge: .bottom) {
            gitPopover(state)
        }
        .hoverTooltip("Choose git diff inclusion for copied context")
    }

    private func copyButtonGridCell(_ state: RenderState) -> some View {
        copyButton(state)
            .frame(maxWidth: .infinity, minHeight: fontPreset.scaledMetric(50), alignment: .center)
    }

    private func copyButton(_ state: RenderState) -> some View {
        Button {
            copyPromptContext()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copyButtonIcon)
                Text(copyButtonTitle)
            }
            .font(fontPreset.captionFont.weight(.semibold))
        }
        .buttonStyle(CustomButtonStyle(verticalPadding: 6, horizontalPadding: 12, height: 30))
        .disabled(copyStatus == .copying)
    }

    private func copyPresetPopover(_ state: RenderState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            popoverHeader(
                title: "Copy Preset",
                subtitle: "Choose how the current prompt and selected context are packaged."
            )

            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.presetOptions) { option in
                    popoverOptionRow(
                        title: option.label,
                        subtitle: option.description,
                        icon: option.icon,
                        isSelected: option.id == state.selectedPresetID
                    ) {
                        promptManager.selectCopyPreset(option.id)
                        copyStatus = .idle
                        showCopyPresetPopover = false
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func fileTreePopover(_ state: RenderState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            popoverHeader(
                title: "File Tree",
                subtitle: "Choose the project structure map included in copied context."
            )

            VStack(alignment: .leading, spacing: 4) {
                ForEach(FileTreeOption.allCases) { option in
                    popoverOptionRow(
                        title: fileTreeLabel(option),
                        subtitle: option.caption,
                        icon: fileTreeIcon(option),
                        isSelected: option == state.resolvedConfig.effectiveFileTreeMode
                    ) {
                        promptManager.updateFileTreeOption(option)
                        copyStatus = .idle
                        showFileTreePopover = false
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func codeMapPopover(_ state: RenderState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            popoverHeader(
                title: "Code Map",
                subtitle: "Choose how source structure is represented in copied context."
            )

            VStack(alignment: .leading, spacing: 4) {
                ForEach(CodeMapUsage.allCases, id: \.rawValue) { usage in
                    popoverOptionRow(
                        title: codeMapLabel(usage),
                        subtitle: usage.caption,
                        icon: codeMapIcon(usage),
                        isSelected: usage == state.resolvedConfig.codeMapUsage
                    ) {
                        promptManager.updateCodeMapUsage(usage)
                        copyStatus = .idle
                        showCodeMapPopover = false
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func gitPopover(_ state: RenderState) -> some View {
        AgentContextDrawerGitPopover(
            gitViewModel: promptManager.gitViewModel,
            currentInclusion: state.resolvedConfig.gitInclusion,
            fontPreset: fontPreset,
            onInclusionChange: { inclusion in
                updateGitInclusion(inclusion, closesPopover: false)
            }
        )
        .onAppear {
            promptManager.gitViewModel.isPopoverVisible = true
            Task {
                await promptManager.gitViewModel.fetchUnstagedFiles(trigger: .popoverOpen)
            }
        }
        .onDisappear {
            promptManager.gitViewModel.isPopoverVisible = false
        }
    }

    private func promptsPopover(_ state: RenderState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            popoverHeader(
                title: "Prompts",
                subtitle: state.isManualPreset
                    ? "Choose stored prompts for Manual copy mode."
                    : "This preset supplies its stored prompt selection."
            )

            if promptManager.storedPrompts.isEmpty {
                emptyPopoverText("No stored prompts available")
            } else if state.isManualPreset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(promptManager.storedPrompts) { prompt in
                            promptSelectionRow(
                                prompt,
                                isSelected: state.selectedPromptIDs.contains(prompt.id),
                                isEditable: true
                            ) {
                                toggleManualPrompt(prompt)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else if state.selectedPrompts.isEmpty {
                emptyPopoverText("No stored prompts selected")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.selectedPrompts) { prompt in
                            promptSelectionRow(prompt, isSelected: true, isEditable: false) {}
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func popoverHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(fontPreset.standardFont.weight(.semibold))
            Text(subtitle)
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func popoverOptionRow(
        title: String,
        subtitle: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(fontPreset.captionFont.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(fontPreset.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .textSelection(.disabled)
        }
        .buttonStyle(.plain)
    }

    private func promptSelectionRow(
        _ prompt: PromptViewModel.StoredPrompt,
        isSelected: Bool,
        isEditable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(prompt.title)
                        .font(fontPreset.captionFont.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEditable)

            AgentContextStoredPromptPreviewButton(prompt: prompt)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isSelected ? Color.teal.opacity(0.10) : Color(NSColor.controlBackgroundColor).opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .textSelection(.disabled)
    }

    private func emptyPopoverText(_ text: String) -> some View {
        Text(text)
            .font(fontPreset.captionFont)
            .foregroundStyle(.tertiary)
            .italic()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func promptSummaryText(_ state: RenderState) -> String {
        guard state.resolvedConfig.includeMetaPrompts else { return "None" }
        let count = state.selectedPrompts.count
        return count == 0 ? "None" : "\(count) stored"
    }

    private func copyPresetFallbackDescription(_ preset: CopyPreset) -> String {
        switch preset.builtInKind {
        case .some(.standard):
            "Balanced copy context for everyday work."
        case .some(.plan):
            "Planning handoff with the Architect stored prompt."
        case .some(.codeReview):
            "Review handoff with selected git diff context."
        case .some(.manual):
            "Use the current manual File Tree, Code Map, Git, and Prompt controls."
        case .some(.diffFollowUp):
            "Git-focused follow-up context."
        case nil:
            "Custom copy preset."
        }
    }

    private func fileTreeLabel(_ option: FileTreeOption) -> String {
        switch option {
        case .none:
            "None"
        case .auto:
            "Auto"
        case .files:
            "Full"
        case .selected:
            "Selected"
        }
    }

    private func fileTreeIcon(_ option: FileTreeOption) -> String {
        switch option {
        case .none:
            "xmark.circle"
        case .auto:
            "arrow.triangle.2.circlepath.circle"
        case .files:
            "list.bullet.rectangle"
        case .selected:
            "target"
        }
    }

    private func codeMapLabel(_ usage: CodeMapUsage) -> String {
        switch usage {
        case .none:
            "None"
        case .selected:
            "Selected"
        case .auto:
            "Auto"
        case .complete:
            "Complete"
        }
    }

    private func codeMapIcon(_ usage: CodeMapUsage) -> String {
        switch usage {
        case .none:
            "xmark.circle"
        case .selected:
            "target"
        case .auto:
            "arrow.triangle.2.circlepath.circle"
        case .complete:
            "checkmark.circle.fill"
        }
    }

    private func gitLabel(_ inclusion: GitInclusion) -> String {
        switch inclusion {
        case .none:
            "None"
        case .selected:
            "Selected"
        case .complete:
            "All"
        }
    }

    private func gitCaption(_ inclusion: GitInclusion) -> String {
        switch inclusion {
        case .none:
            "Do not include git diff context"
        case .selected:
            "Include selected git diff context"
        case .complete:
            "Include the complete git diff"
        }
    }

    private func gitIcon(_ inclusion: GitInclusion) -> String {
        switch inclusion {
        case .none:
            "circle"
        case .selected:
            "smallcircle.filled.circle"
        case .complete:
            "circle.fill"
        }
    }

    private func updateGitInclusion(_ inclusion: GitInclusion, closesPopover: Bool = true) {
        promptManager.updateGitInclusion(gitDiffMode(for: inclusion))
        var customizations = promptManager.workingCopyCustomizations
        customizations.gitInclusion = inclusion
        promptManager.workingCopyCustomizations = customizations
        copyStatus = .idle
        if closesPopover {
            showGitPopover = false
        }
    }

    private func gitDiffMode(for inclusion: GitInclusion) -> GitDiffInclusionMode {
        switch inclusion {
        case .none:
            .none
        case .selected:
            .selectedFiles
        case .complete:
            .all
        }
    }

    private var copyButtonIcon: String {
        switch copyStatus {
        case .idle:
            "doc.on.clipboard"
        case .copying:
            "hourglass"
        case .copied:
            "checkmark"
        }
    }

    private var copyButtonTitle: String {
        switch copyStatus {
        case .idle:
            "Copy Prompt"
        case .copying:
            "Copying"
        case .copied:
            "Copy Prompt"
        }
    }

    private func copyPromptContext() {
        let currentPreset = promptManager.currentCopyPreset()
        let cfg = promptManager.resolvePromptContext()
        copyStatus = .copying
        let selectedPromptIDsOverride = currentPreset.builtInKind == .manual
            ? promptManager.promptSelection(for: .copy).sorted { $0.uuidString < $1.uuidString }
            : nil
        Task {
            let clipboard = await exportContext.buildClipboardContent(
                for: cfg,
                model: modelCoordinator.model,
                selectedPromptIDsOverride: selectedPromptIDsOverride
            )
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clipboard, forType: .string)
                copyStatus = .copied
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                if copyStatus == .copied {
                    copyStatus = .idle
                }
            }
        }
    }

    private func toggleManualPrompt(_ prompt: PromptViewModel.StoredPrompt) {
        guard promptManager.currentCopyPreset().builtInKind == .manual else { return }
        var next = promptManager.promptSelection(for: .copy)
        if next.contains(prompt.id) {
            next.remove(prompt.id)
        } else {
            next.insert(prompt.id)
        }
        promptManager.updatePromptSelection(next, for: .copy)
        copyStatus = .idle
    }
}

private struct AgentContextDrawerGitPopover: View {
    @ObservedObject var gitViewModel: GitViewModel
    let currentInclusion: GitInclusion
    let fontPreset: FontScalePreset
    let onInclusionChange: (GitInclusion) -> Void

    @State private var isCopyingSelected = false
    @State private var isCopyingAll = false
    @State private var showCopiedSelectedFeedback = false
    @State private var showCopiedAllFeedback = false

    private var includeModeBinding: Binding<GitInclusion> {
        Binding(
            get: { currentInclusion },
            set: { onInclusionChange($0) }
        )
    }

    private var selectedVisibleFileCount: Int {
        gitViewModel.filteredUnstagedFiles.count { gitViewModel.isFileSelected($0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            rootSection
            includeModeSection
            compareSection
            changedFilesSection
        }
        .padding(12)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Git")
                .font(fontPreset.standardFont.weight(.semibold))
            Text("Selected includes the checked pending changes below. Working changes are compared to the chosen target.")
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var rootSection: some View {
        if gitViewModel.gitEnabledRootFolders.isEmpty {
            compactInfoRow(icon: "minus.circle", text: "No git repositories available in this workspace")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Root")
                        .font(fontPreset.captionFont.weight(.semibold))
                    Spacer()
                    if let branch = gitViewModel.currentBranch {
                        Text(branch)
                            .font(fontPreset.captionFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }

                if gitViewModel.gitEnabledRootFolders.count > 1 {
                    Picker("Root", selection: $gitViewModel.selectedRootFolder) {
                        ForEach(gitViewModel.gitEnabledRootFolders, id: \.id) { folder in
                            Text(folder.name).tag(folder as FolderViewModel?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } else if let root = gitViewModel.selectedRootFolder ?? gitViewModel.gitEnabledRootFolders.first {
                    Text(root.name)
                        .font(fontPreset.captionFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.38))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private var includeModeSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Include")
                .font(fontPreset.captionFont.weight(.semibold))
            Picker("Include", selection: includeModeBinding) {
                Text("None").tag(GitInclusion.none)
                Text("Selected").tag(GitInclusion.selected)
                Text("All").tag(GitInclusion.complete)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var compareSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Compare working changes with")
                .font(fontPreset.captionFont.weight(.semibold))
            Picker("Compare", selection: $gitViewModel.selectedDiffBranch) {
                Text(headCompareLabel).tag("HEAD")
                if !gitViewModel.availableBranches.isEmpty {
                    Divider()
                    ForEach(gitViewModel.availableBranches, id: \.name) { branch in
                        Text(branch.isCurrent ? "\(branch.name) (current)" : branch.name)
                            .tag(branch.name)
                    }
                }
                if !gitViewModel.availableRemoteBranches.isEmpty {
                    Divider()
                    ForEach(gitViewModel.availableRemoteBranches, id: \.name) { branch in
                        Text(branch.name).tag(branch.name)
                    }
                }
                if !gitViewModel.availableTags.isEmpty {
                    Divider()
                    ForEach(gitViewModel.availableTags, id: \.name) { tag in
                        Text(tag.name).tag(tag.name)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!gitViewModel.hasValidRepository)
        }
    }

    private var changedFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Pending changes")
                    .font(fontPreset.captionFont.weight(.semibold))
                if !gitViewModel.unstagedFiles.isEmpty {
                    Text("\(gitViewModel.unstagedFiles.count)")
                        .font(fontPreset.captionFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)
                        )
                }
                if gitViewModel.isLoadingStatus {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
                Spacer()
            }

            actionButtons

            GitSearchField(gitViewModel: gitViewModel, fontPreset: fontPreset)

            if let error = gitViewModel.errorMessage {
                compactInfoRow(icon: "exclamationmark.triangle", text: error)
                    .frame(height: 172)
            } else if gitViewModel.filteredUnstagedFiles.isEmpty {
                compactInfoRow(icon: "checkmark.circle", text: emptyChangedFilesText)
                    .frame(height: 172)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(gitViewModel.filteredUnstagedFiles, id: \.path) { file in
                            AgentContextDrawerGitFileRow(
                                gitViewModel: gitViewModel,
                                file: file,
                                fontPreset: fontPreset
                            )
                        }
                    }
                    .padding(6)
                }
                .frame(height: 172)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
                )
            }

            Text(selectedVisibleFileCount == 1 ? "1 visible file checked" : "\(selectedVisibleFileCount) visible files checked")
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
        }
    }

    private var headCompareLabel: String {
        if let currentBranch = gitViewModel.currentBranch {
            return "HEAD (\(currentBranch))"
        }
        return "HEAD"
    }

    private var emptyChangedFilesText: String {
        gitViewModel.fileSearchText.isEmpty ? "No pending changes" : "No changed files match the filter"
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button("Select All") {
                selectVisibleFiles()
            }
            .font(fontPreset.captionFont)
            .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 7, height: 24))
            .disabled(gitViewModel.filteredUnstagedFiles.isEmpty || gitViewModel.isBulkSelectionRunning)
            .hoverTooltip("Add visible changed files to selection")

            Button("Clear") {
                clearSelectedChangedFiles()
            }
            .font(fontPreset.captionFont)
            .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 7, height: 24))
            .disabled(!gitViewModel.hasTrackedSelectedChangedFiles || gitViewModel.isBulkSelectionRunning)
            .hoverTooltip("Remove selected changed files from selection")

            Button(showCopiedSelectedFeedback ? "Copied!" : "Copy Selected") {
                copySelectedDiff()
            }
            .font(fontPreset.captionFont)
            .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 7, height: 24))
            .disabled(!gitViewModel.hasCurrentSelectedChangedFiles || isCopyingSelected || showCopiedSelectedFeedback)
            .opacity(showCopiedSelectedFeedback ? 0.7 : 1.0)
            .hoverTooltip("Copy diff of selected files")

            Button(showCopiedAllFeedback ? "Copied!" : "Copy All") {
                copyAllDiff()
            }
            .font(fontPreset.captionFont)
            .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 7, height: 24))
            .disabled(gitViewModel.unstagedFiles.isEmpty || isCopyingAll || showCopiedAllFeedback)
            .opacity(showCopiedAllFeedback ? 0.7 : 1.0)
            .hoverTooltip("Copy diff of all working tree files")
        }
    }

    private func selectVisibleFiles() {
        Task {
            await gitViewModel.addFilteredUnstagedToFileManager()
        }
    }

    private func clearSelectedChangedFiles() {
        Task {
            await gitViewModel.clearSelectedChangedFilesFromFileManager()
        }
    }

    private func copySelectedDiff() {
        isCopyingSelected = true
        Task { @MainActor in
            let success = await gitViewModel.copySelectedDiff()
            isCopyingSelected = false
            guard success else { return }
            showCopiedSelectedFeedback = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showCopiedSelectedFeedback = false
        }
    }

    private func copyAllDiff() {
        isCopyingAll = true
        Task { @MainActor in
            let success = await gitViewModel.copyAllDiff()
            isCopyingAll = false
            guard success else { return }
            showCopiedAllFeedback = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showCopiedAllFeedback = false
        }
    }

    private func compactInfoRow(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct GitSearchField: View {
    @ObservedObject var gitViewModel: GitViewModel
    let fontPreset: FontScalePreset

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(fontPreset.captionFont)
                .foregroundStyle(.secondary)
            TextField("Filter changed files", text: $gitViewModel.fileSearchText)
                .textFieldStyle(.plain)
                .font(fontPreset.captionFont)
            if !gitViewModel.fileSearchText.isEmpty {
                Button {
                    gitViewModel.clearFileSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(fontPreset.captionFont)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct AgentContextDrawerGitFileRow: View {
    @ObservedObject var gitViewModel: GitViewModel
    let file: VCSUncommittedFile
    let fontPreset: FontScalePreset

    private var isSelected: Bool {
        gitViewModel.isFileSelected(file.path)
    }

    var body: some View {
        Button {
            toggleSelection()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)

                Text(file.status)
                    .font(.system(size: fontPreset.scaledClamped(10, min: 10, max: 12), weight: .medium, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .frame(width: 22, alignment: .leading)

                HStack(spacing: 3) {
                    if let additions = file.additions, additions > 0 {
                        Text("+\(additions)")
                            .foregroundStyle(.green)
                    }
                    if let deletions = file.deletions, deletions > 0 {
                        Text("-\(deletions)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: fontPreset.scaledClamped(10, min: 10, max: 12), design: .monospaced))
                .frame(width: 54, alignment: .leading)

                Text(file.path)
                    .font(.system(size: fontPreset.scaledClamped(10, min: 10, max: 12), design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .textSelection(.disabled)
    }

    private var statusColor: Color {
        if file.status.contains("D") { return .red }
        if file.status.contains("A") || file.status == "??" { return .green }
        if file.status.contains("R") { return .purple }
        return .orange
    }

    private func toggleSelection() {
        Task {
            if isSelected {
                await gitViewModel.removeFileFromSelection(file.path)
            } else {
                await gitViewModel.addFileToSelection(file.path)
            }
        }
    }
}

private struct AgentContextPromptInstructionsEditor: View {
    @Binding var text: String
    let fontPreset: FontScalePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Receiving-model instructions")
                    .font(fontPreset.standardFont.weight(.semibold))
                Text("Tell the model what to do with this selected context.")
                    .font(fontPreset.captionFont)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(fontPreset.standardFont)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 154)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Plan a fix, review the selected changes, or ask a specific question about this context.")
                        .font(fontPreset.captionFont)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(Color(NSColor.textBackgroundColor).opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
        }
    }
}

private struct AgentContextDrawerControlLabel: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    let fontPreset: FontScalePreset

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                .foregroundStyle(isEnabled ? tint : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(fontPreset.captionFont.weight(.semibold))
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.down")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(isEnabled ? 1 : 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(NSColor.controlBackgroundColor)
                .opacity(isHovering ? 0.55 : 0.30)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(isHovering ? 0.35 : 0.20), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .textSelection(.disabled)
        .onHover { isHovering = $0 }
    }
}

private struct AgentContextStoredPromptPreviewButton: View {
    let prompt: PromptViewModel.StoredPrompt

    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var showPreview = false

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        Button {
            showPreview = true
        } label: {
            Image(systemName: "eye")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .hoverTooltip("Preview prompt")
        .popover(isPresented: $showPreview) {
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt.title)
                    .font(fontPreset.standardFont.weight(.semibold))
                ScrollView {
                    Text(prompt.content)
                        .font(fontPreset.standardFont)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 360, height: 260)
            }
            .padding(12)
        }
    }
}
