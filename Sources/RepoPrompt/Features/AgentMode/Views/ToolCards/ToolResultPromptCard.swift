import Foundation
import SwiftUI

struct PromptResultCard: View {
    let item: AgentChatItem
    let promptManager: PromptViewModel?
    @State private var isExpanded: Bool

    private func compactIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.count <= 24 {
            return value
        }
        return String(value.prefix(8)) + "…" + String(value.suffix(6))
    }

    init(item: AgentChatItem, promptManager: PromptViewModel? = nil) {
        self.item = item
        self.promptManager = promptManager
        _isExpanded = State(initialValue: Self.shouldAutoExpandInitially(item: item))
    }

    private static func shouldAutoExpandInitially(item: AgentChatItem) -> Bool {
        guard toolResultHasPayload(item), item.toolIsError != true else { return false }
        guard let dto = ToolJSON.decode(ToolResultDTOs.PromptToolEnvelope.self, from: item.toolResultJSON) else {
            return false
        }
        return dto.op.lowercased() == "export" && dto.export != nil
    }

    private var dto: ToolResultDTOs.PromptToolEnvelope? {
        ToolJSON.decode(ToolResultDTOs.PromptToolEnvelope.self, from: item.toolResultJSON)
    }

    private var exportReply: ToolResultDTOs.PromptExportReply? {
        guard let dto, dto.op.lowercased() == "export" else { return nil }
        return dto.export
    }

    private var isExportResult: Bool {
        exportReply != nil
    }

    private var summary: String {
        if let dto {
            switch dto.op.lowercased() {
            case "get", "set", "append", "clear":
                if let lines = dto.prompt?.lines {
                    return "\(dto.op) • \(lines) lines"
                }
                return dto.op
            case "export":
                if let export = dto.export {
                    var parts: [String] = [fileName(from: export.path)]
                    if !export.files.isEmpty {
                        parts.append("\(export.files.count) files")
                    }
                    parts.append("~\(AgentContextIndicator.formatTokens(export.tokens)) tokens")
                    if let presetName = export.copyPreset?.name, !presetName.isEmpty {
                        parts.append(presetName)
                    }
                    return parts.joined(separator: " • ")
                }
                return dto.op
            case "list_presets":
                let count = dto.presetsList?.presets.count ?? 0
                return "list_presets • \(count) presets"
            case "select_preset":
                if let name = dto.selectedPreset?.name {
                    return "select_preset • \(name)"
                }
                return dto.op
            default:
                return dto.op
            }
        }
        if let args = ToolJSON.decodeArgs(ToolArgsDTOs.PromptArgs.self, from: item.toolArgsJSON),
           let op = args.op?.lowercased()
        {
            if op == "export", let path = args.path, !path.isEmpty {
                return "export • \(fileName(from: path))"
            }
            return op
        }
        return ""
    }

    private var title: String {
        guard let op = dto?.op.lowercased() else { return "Prompt" }
        return op == "export" ? "Prompt Export" : "Prompt"
    }

    private var detailText: String? {
        guard let dto else { return nil }
        switch dto.op.lowercased() {
        case "export":
            return nil
        case "list_presets":
            let presets = dto.presetsList?.presets ?? []
            guard !presets.isEmpty else { return nil }
            let visible = presets.prefix(2).map(\.preset.name)
            var parts = visible
            if presets.count > visible.count {
                parts.append("(+\(presets.count - visible.count) more)")
            }
            return parts.joined(separator: " • ")
        case "select_preset":
            return compactIdentifier(dto.selectedPreset?.id)
        default:
            return nil
        }
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true {
            return .failure
        }
        if let dto {
            switch dto.op.lowercased() {
            case "get", "set", "append", "clear", "export", "list_presets", "select_preset":
                return .success
            default:
                break
            }
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    private func reconcileExpansion() {
        guard isExportResult else { return }
        let shouldExpand = toolResultHasPayload(item) && item.toolIsError != true
        guard isExpanded != shouldExpand else { return }
        performAgentToolCardExpansionStateUpdateWithoutAnimation {
            isExpanded = shouldExpand
        }
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: title,
            detailText: nil,
            subtitle: inlineToolCardSummary(summary, detailText),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            managesOwnExpansion: isExportResult,
            isExpanded: $isExpanded
        ) {
            if let exportReply {
                if let promptManager {
                    let resolvedExportPreset = promptExportResolvedPreset(exportReply.copyPreset)
                    let fallbackPreset = exportReply.copyPreset == nil ? promptManager.currentCopyPreset() : nil
                    let copyPreset = resolvedExportPreset ?? fallbackPreset
                    let displayedPresetName = {
                        let trimmed = exportReply.copyPreset?.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed?.isEmpty == false {
                            return trimmed!
                        }
                        return copyPreset?.name ?? promptManager.currentCopyPreset().name
                    }()
                    let copyAction: (() -> Void)? = copyPreset.map { preset in
                        { promptManager.performCopy(using: preset, openApplyXMLTab: false) }
                    }
                    PromptExportExpandedContent(
                        item: item,
                        export: exportReply,
                        presetName: displayedPresetName,
                        canCopy: exportReply.copyPreset == nil || resolvedExportPreset != nil,
                        copyUnavailableReason: (exportReply.copyPreset != nil && resolvedExportPreset == nil) ? "Export preset is unavailable locally." : nil,
                        onCopy: copyAction
                    )
                } else {
                    PromptExportExpandedFallbackContent(item: item, export: exportReply)
                }
            } else {
                ToolMarkdownExpandedContent(item: item)
            }
        }
        .onAppear {
            reconcileExpansion()
        }
        .onChange(of: item.toolResultJSON) { _, _ in
            reconcileExpansion()
        }
    }
}

private struct PromptExportExpandedContent: View {
    let item: AgentChatItem
    let export: ToolResultDTOs.PromptExportReply
    let presetName: String
    let canCopy: Bool
    let copyUnavailableReason: String?
    let onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolCardPromptCopyActionView(
                label: "Copy Prompt",
                presetName: presetName,
                canCopy: canCopy,
                unavailableReason: copyUnavailableReason,
                tokenCountProvider: {
                    export.tokens
                },
                onCopy: {
                    onCopy?()
                }
            )

            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct ToolCardPromptCopyActionView<TrailingContent: View>: View {
    let label: String
    let presetName: String
    let canCopy: Bool
    let unavailableReason: String?
    let tokenCountProvider: () async -> Int
    let onCopy: @MainActor () -> Void
    private let trailingContent: TrailingContent

    @State private var showCopied = false

    init(
        label: String,
        presetName: String,
        canCopy: Bool,
        unavailableReason: String?,
        tokenCountProvider: @escaping () async -> Int,
        onCopy: @escaping @MainActor () -> Void,
        @ViewBuilder trailingContent: () -> TrailingContent = { EmptyView() }
    ) {
        self.label = label
        self.presetName = presetName
        self.canCopy = canCopy
        self.unavailableReason = unavailableReason
        self.tokenCountProvider = tokenCountProvider
        self.onCopy = onCopy
        self.trailingContent = trailingContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Button(action: triggerCopy) {
                    Label(showCopied ? "Copied!" : label, systemImage: showCopied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 90, minHeight: 16)
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(!canCopy)

                HStack(spacing: 3) {
                    Text("Preset:")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(presetName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                trailingContent
            }

            if let unavailableReason {
                Text(unavailableReason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func triggerCopy() {
        guard canCopy else { return }
        Task {
            _ = await tokenCountProvider()
            await MainActor.run {
                onCopy()
                withAnimation(.easeInOut(duration: 0.15)) {
                    showCopied = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showCopied = false
                }
            }
        }
    }
}

@MainActor
private func promptExportResolvedPreset(_ descriptor: ToolResultDTOs.CopyPresetDescriptorDTO?) -> CopyPreset? {
    guard let descriptor else { return nil }
    if let id = UUID(uuidString: descriptor.id),
       let preset = CopyPresetManager.shared.preset(with: id)
    {
        return preset
    }
    if let kindRaw = descriptor.kind,
       let kind = CopyPresetKind(rawValue: kindRaw),
       let preset = CopyPresetManager.shared.builtInPreset(for: kind)
    {
        return preset
    }
    return nil
}

private struct PromptExportExpandedFallbackContent: View {
    let item: AgentChatItem
    let export: ToolResultDTOs.PromptExportReply

    private var exportPresetName: String? {
        let trimmed = export.copyPreset?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Copy Prompt unavailable", systemImage: "doc.on.clipboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if let exportPresetName {
                Text("Export used \(exportPresetName).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ToolMarkdownExpandedContent(item: item)
        }
    }
}
