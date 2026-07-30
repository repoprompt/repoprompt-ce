import SwiftUI

struct SettingsChatPresetPickerPopover<Preview: View>: View {
    let allPresets: [ChatPreset]
    let selectedId: UUID
    let fontPreset: FontScalePreset
    let windowID: Int
    let previewBuilder: (ChatPreset) -> Preview
    let onSelect: (ChatPreset) -> Void

    @State private var hoveredId: UUID?

    private var standardPresets: [ChatPreset] {
        allPresets.filter { preset in
            !preset.name.hasPrefix("MCP")
        }.sorted { first, second in
            if first.name == "Manual" {
                return false
            }
            if second.name == "Manual" {
                return true
            }
            return allPresets.firstIndex(where: { $0.id == first.id })! <
                allPresets.firstIndex(where: { $0.id == second.id })!
        }
    }

    private var mcpPresets: [ChatPreset] {
        allPresets.filter { preset in
            preset.name.hasPrefix("MCP")
        }
    }

    var body: some View {
        HStack(spacing: 10 * fontPreset.scaleFactor) {
            previewPane
            presetList
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 6 * fontPreset.scaleFactor) {
            if let preset = allPresets.first(where: { $0.id == (hoveredId ?? selectedId) }) {
                previewBuilder(preset)
            }
            Spacer()
        }
        .frame(width: 320 * fontPreset.scaleFactor, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }

    private var presetList: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Spacer().frame(height: 4)
                    if !standardPresets.isEmpty {
                        presetsSection(title: "Standard Modes", presets: standardPresets, fallbackSystemSymbol: "bubble.left.and.bubble.right")
                    }
                    if !mcpPresets.isEmpty {
                        presetsSection(title: "MCP-Powered Modes", presets: mcpPresets, fallbackSystemSymbol: "cpu")
                            .padding(.top, 6)
                    }
                }
            }

            managePresetsButton
        }
    }

    private func presetsSection(title: String, presets: [ChatPreset], fallbackSystemSymbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(fontPreset.captionFont.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            ForEach(presets, id: \.id) { preset in
                SettingsChatPresetOptionRow(
                    leadingEmoji: preset.icon,
                    fallbackSystemSymbol: fallbackSystemSymbol,
                    title: preset.name,
                    subtitle: nil,
                    isSelected: preset.id == selectedId
                )
                .equatable()
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        hoveredId = preset.id
                    }
                }
                .onTapGesture {
                    onSelect(preset)
                }
            }
        }
    }

    private var managePresetsButton: some View {
        Button(action: {
            NotificationCenter.default.post(
                name: .showChatPresetsTab,
                object: nil,
                userInfo: ["windowID": windowID]
            )
            if let current = allPresets.first(where: { $0.id == selectedId }) {
                onSelect(current)
            } else if let fallback = allPresets.first {
                onSelect(fallback)
            }
        }) {
            Image(systemName: "gearshape")
                .font(fontPreset.standardFont)
                .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
        .hoverTooltip("Manage Chat Presets")
        .padding(.trailing, 4)
        .padding(.top, 0)
    }
}

private struct SettingsChatPresetOptionRow: View, Equatable {
    let leadingEmoji: String?
    let fallbackSystemSymbol: String
    let title: String
    let subtitle: String?
    let isSelected: Bool

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let leadingEmoji, !leadingEmoji.isEmpty {
                Text(leadingEmoji)
                    .font(.system(size: 14 * fontPreset.scaleFactor))
            } else {
                Image(systemName: fallbackSystemSymbol)
                    .font(.system(size: 12 * fontPreset.scaleFactor))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(fontPreset.standardFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11 * fontPreset.scaleFactor))
            }
        }
        .frame(height: fontPreset.scaledClamped(28, min: 28, max: 36))
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.75) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.systemGray).opacity(isHovering ? 0.6 : 0.3), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    static func == (lhs: SettingsChatPresetOptionRow, rhs: SettingsChatPresetOptionRow) -> Bool {
        lhs.leadingEmoji == rhs.leadingEmoji &&
            lhs.fallbackSystemSymbol == rhs.fallbackSystemSymbol &&
            lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.isSelected == rhs.isSelected
    }
}

struct SettingsChatPresetPreviewView: View {
    let preset: ChatPreset
    let fontPreset: FontScalePreset

    private var presetSubtitle: String {
        if preset.isBuiltIn {
            ChatPresetManager.shared.hasOverrides(preset.id) ? "Built-in (modified)" : "Built-in preset"
        } else {
            "Custom preset"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            contextConfiguration
            Divider()
            usageSection(title: "When to use", text: chatWhenToUseDescription)
            usageSection(title: "About this mode", text: chatModeDescription)
        }
    }

    private var header: some View {
        HStack {
            if let icon = preset.icon, !icon.isEmpty {
                Text(icon)
                    .font(.system(size: 24))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.primary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(fontPreset.headlineFont)
                    .foregroundColor(.primary)
                Text(presetSubtitle)
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var contextConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Configuration")
                .font(fontPreset.captionFont.bold())
                .foregroundColor(.primary)

            LazyVGrid(columns: chatGridColumns, alignment: .leading, spacing: 10) {
                SettingsChatModeTile(
                    iconName: chatModeIcon(for: preset.mode),
                    title: "Mode",
                    detail: preset.mode.displayName,
                    active: true,
                    accentColor: chatModeColor(for: preset.mode)
                )

                SettingsChatModeTile(
                    iconName: "doc.on.doc",
                    title: "Selected Files",
                    detail: "Current selection",
                    active: true
                )

                if let fileTreeMode = preset.fileTreeMode {
                    SettingsChatModeTile(
                        iconName: fileTreeIcon(for: fileTreeMode),
                        title: "Project Structure",
                        detail: fileTreeMode.rawValue,
                        active: fileTreeMode != .none
                    )
                }

                if let codeMapUsage = preset.codeMapUsage {
                    SettingsChatModeTile(
                        iconName: codeMapUsage != .none ? codeMapIcon(for: codeMapUsage) : "xmark.circle",
                        title: "Code Map",
                        detail: codeMapUsage != .none ? codeMapUsage.rawValue : "Excluded",
                        active: codeMapUsage != .none
                    )
                }

                if let gitInclusion = preset.gitInclusion {
                    SettingsChatModeTile(
                        iconName: gitIcon(for: gitInclusion),
                        title: "Git Diff",
                        detail: gitInclusion.rawValue,
                        active: gitInclusion != .none
                    )
                }

                if let modelName = preset.modelPresetName,
                   let model = AIModel.fromModelName(modelName)
                {
                    SettingsChatModeTile(
                        iconName: "cpu",
                        title: "Model",
                        detail: truncatedModelName(model.displayName),
                        active: true
                    )
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.systemGray).opacity(0.25), lineWidth: 0.5)
        )
    }

    private func usageSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(fontPreset.captionFont.bold())
                .foregroundColor(.primary)
            Text(text)
                .font(fontPreset.standardFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chatGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10, alignment: .topLeading),
            GridItem(.flexible(), spacing: 10, alignment: .topLeading)
        ]
    }

    private func truncatedModelName(_ name: String) -> String {
        if name.contains("claude") {
            return name.replacingOccurrences(of: "claude-", with: "")
        }
        if name.count > 20 {
            return String(name.prefix(18)) + "…"
        }
        return name
    }

    private func chatModeIcon(for mode: ChatPresetMode) -> String {
        switch mode {
        case .chat: "bubble.left.and.bubble.right"
        case .plan: "map"
        case .review: "magnifyingglass"
        }
    }

    private func chatModeColor(for mode: ChatPresetMode) -> Color {
        switch mode {
        case .chat: .blue
        case .plan: .purple
        case .review: .teal
        }
    }

    private func fileTreeIcon(for mode: FileTreeOption) -> String {
        switch mode {
        case .auto: "arrow.triangle.2.circlepath.circle"
        case .files: "list.bullet.rectangle"
        case .selected: "target"
        case .none: "xmark.circle"
        }
    }

    private func codeMapIcon(for usage: CodeMapUsage) -> String {
        switch usage {
        case .auto: "arrow.triangle.2.circlepath.circle"
        case .complete: "checkmark.circle.fill"
        case .selected: "target"
        case .none: "xmark.circle"
        }
    }

    private func gitIcon(for inclusion: GitInclusion) -> String {
        switch inclusion {
        case .none: "circle"
        case .selected: "smallcircle.filled.circle"
        case .complete: "circle.fill"
        }
    }

    private var chatWhenToUseDescription: String {
        if preset.name == "Standard" {
            return "• General discussions and exploration\n• Understanding existing code\n• Debugging and troubleshooting"
        } else if preset.name == "Plan" {
            return "• Complex features needing design\n• Architecture decisions required\n• Multi-step implementation planning"
        } else if preset.name == "Manual" {
            return "• Custom workflow requirements\n• Full control over context\n• Advanced configuration needs"
        } else if preset.name == "Diff Follow-Up" {
            return "• Track progress against external plan\n• Verify changes align with strategy\n• Review recent commits"
        } else if preset.name == "Review" {
            return "• Code review sessions\n• Quality assessments\n• Pre-merge checks"
        }

        switch preset.mode {
        case .chat:
            return "• Interactive discussions\n• Code exploration\n• Debugging sessions"
        case .plan:
            return "• Implementation planning\n• Architecture design\n• Task breakdown"
        case .review:
            return "• Code review with git diffs\n• Change analysis\n• Quality feedback"
        }
    }

    private var chatModeDescription: String {
        let baseDescription = switch preset.mode {
        case .chat:
            "Unconstrained chat focused on file context. Steerable via Meta Prompts."
        case .plan:
            "Focused architectural planning from file context."
        case .review:
            "Code review mode with git diff context for analyzing changes."
        }

        return baseDescription + " Uses your current file selection and workspace settings."
    }
}

private struct SettingsChatModeTile: View {
    let iconName: String
    let title: String
    let detail: String
    let active: Bool
    var accentColor: Color?

    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        HStack(spacing: 6 * fontPreset.scaleFactor) {
            Image(systemName: iconName)
                .font(.system(size: 12 * fontPreset.scaleFactor))
                .foregroundColor(accentColor ?? (active ? .accentColor : .secondary))
                .frame(width: 16 * fontPreset.scaleFactor, height: 16 * fontPreset.scaleFactor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2 * fontPreset.scaleFactor) {
                Text(title)
                    .font(fontPreset.captionFont.bold())
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(detail)
                    .font(fontPreset.captionFont)
                    .foregroundColor(active ? .secondary : .secondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, fontPreset.scaledClamped(6, min: 6, max: 9))
        .padding(.vertical, fontPreset.scaledClamped(5, min: 5, max: 8))
        .background(
            Color(nsColor: .controlBackgroundColor)
                .opacity(active ? 0.45 : 0.25)
        )
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor?.opacity(0.3) ?? (active ? Color(NSColor.systemGray).opacity(0.4) : Color(NSColor.systemGray).opacity(0.25)), lineWidth: 0.5)
        )
    }
}
