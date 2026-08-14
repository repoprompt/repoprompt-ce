import AppKit
import SwiftUI

@MainActor
enum AgentContextStoredPromptClipboard {
    static func write(
        prompt: PromptViewModel.StoredPrompt,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let intent = PromptClipboardIntentCoordinator.shared.begin()
        return PromptClipboardIntentCoordinator.shared.write(prompt.content, intent: intent, to: pasteboard)
    }

    static func write(
        promptID: UUID,
        from prompts: [PromptViewModel.StoredPrompt],
        to pasteboard: NSPasteboard = .general
    ) -> Bool? {
        guard let prompt = prompts.first(where: { $0.id == promptID }) else { return nil }
        return write(prompt: prompt, to: pasteboard)
    }

    static func writeFullContext(
        _ content: String,
        intent: UInt,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        PromptClipboardIntentCoordinator.shared.write(content, intent: intent, to: pasteboard)
    }
}

struct AgentContextStoredPromptRowPresentation: Identifiable {
    enum Access {
        case manualBuiltIn(isSelected: Bool)
        case manualCustom(isSelected: Bool)
        case presetSupplied
    }

    let prompt: PromptViewModel.StoredPrompt
    let access: Access

    var id: UUID {
        prompt.id
    }

    var isSelected: Bool {
        switch access {
        case let .manualBuiltIn(isSelected), let .manualCustom(isSelected):
            isSelected
        case .presetSupplied:
            true
        }
    }

    var allowsSelectionMutation: Bool {
        switch access {
        case .manualBuiltIn, .manualCustom:
            true
        case .presetSupplied:
            false
        }
    }

    var allowsCopy: Bool {
        switch access {
        case .manualBuiltIn, .manualCustom:
            true
        case .presetSupplied:
            false
        }
    }

    var allowsDestructiveManagement: Bool {
        if case .manualCustom = access {
            return true
        }
        return false
    }
}

struct AgentContextStoredPromptRow: View {
    let presentation: AgentContextStoredPromptRowPresentation
    let fontPreset: FontScalePreset
    let onToggle: () -> Void
    let onCopy: (UUID) -> Bool
    let onEdit: (UUID) -> Void
    let onConfirmDelete: (PromptViewModel.StoredPrompt) -> Void

    @State private var deleteTarget: PromptViewModel.StoredPrompt?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Image(systemName: presentation.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                        .foregroundStyle(presentation.isSelected ? Color.accentColor : Color.secondary)
                    Text(presentation.prompt.title)
                        .font(fontPreset.captionFont.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!presentation.allowsSelectionMutation)

            AgentContextStoredPromptActions(
                presentation: presentation,
                fontPreset: fontPreset,
                onCopy: onCopy,
                onEdit: onEdit,
                onRequestDelete: { deleteTarget = presentation.prompt }
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            presentation.isSelected
                ? Color.teal.opacity(0.10)
                : Color(NSColor.controlBackgroundColor).opacity(0.18)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .textSelection(.disabled)
        .popover(
            isPresented: deleteConfirmationBinding,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            deleteConfirmation
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTarget = nil
                }
            }
        )
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete stored prompt?")
                .font(.headline)
            Text("This permanently deletes “\(deleteTarget?.title ?? presentation.prompt.title)” and removes it from Copy and Chat prompt selections.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    deleteTarget = nil
                }
                Button("Delete", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    deleteTarget = nil
                    onConfirmDelete(target)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 280)
    }
}

private struct AgentContextStoredPromptActions: View {
    let presentation: AgentContextStoredPromptRowPresentation
    let fontPreset: FontScalePreset
    let onCopy: (UUID) -> Bool
    let onEdit: (UUID) -> Void
    let onRequestDelete: () -> Void

    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 2) {
            AgentContextStoredPromptPreviewButton(
                prompt: presentation.prompt,
                fontPreset: fontPreset
            )

            if presentation.allowsCopy {
                actionButton(
                    icon: copied ? "checkmark" : "doc.on.doc",
                    tooltip: copied ? "Copied prompt" : "Copy prompt",
                    accessibilityLabel: copied ? "Copied \(presentation.prompt.title)" : "Copy \(presentation.prompt.title)"
                ) {
                    guard onCopy(presentation.id) else { return }
                    copied = true
                    copiedResetTask?.cancel()
                    copiedResetTask = Task {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                }
            }

            if presentation.allowsDestructiveManagement {
                actionButton(
                    icon: "pencil",
                    tooltip: "Edit prompt",
                    accessibilityLabel: "Edit \(presentation.prompt.title)"
                ) {
                    onEdit(presentation.id)
                }
                actionButton(
                    icon: "trash",
                    tooltip: "Delete prompt",
                    accessibilityLabel: "Delete \(presentation.prompt.title)",
                    tint: .red
                ) {
                    onRequestDelete()
                }
            }
        }
        .onDisappear {
            copiedResetTask?.cancel()
            copiedResetTask = nil
            copied = false
        }
    }

    private func actionButton(
        icon: String,
        tooltip: String,
        accessibilityLabel: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .buttonStyle(SmallRoundButtonStyle(size: 24, iconSize: 11))
        .hoverTooltip(tooltip)
        .accessibilityLabel(accessibilityLabel)
    }
}

enum AgentContextStoredPromptEditorMode: Identifiable {
    case create(id: UUID)
    case edit(PromptViewModel.StoredPrompt)

    var id: UUID {
        switch self {
        case let .create(id):
            id
        case let .edit(prompt):
            prompt.id
        }
    }

    var title: String {
        switch self {
        case .create:
            "New Stored Prompt"
        case .edit:
            "Edit Stored Prompt"
        }
    }

    var initialTitle: String {
        switch self {
        case .create:
            ""
        case let .edit(prompt):
            prompt.title
        }
    }

    var initialContent: String {
        switch self {
        case .create:
            ""
        case let .edit(prompt):
            prompt.content
        }
    }
}

struct AgentContextStoredPromptEditorSheet: View {
    let mode: AgentContextStoredPromptEditorMode
    let onCreate: (String, String) -> PromptViewModel.StoredPromptCreateResult
    let onSave: (PromptViewModel.StoredPrompt, String, String) -> PromptViewModel.StoredPromptEditResult

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var fontScale = FontScaleManager.shared
    @State private var title: String
    @State private var content: String
    @State private var errorMessage: String?
    @State private var saveBlocked = false

    init(
        mode: AgentContextStoredPromptEditorMode,
        onCreate: @escaping (String, String) -> PromptViewModel.StoredPromptCreateResult,
        onSave: @escaping (PromptViewModel.StoredPrompt, String, String) -> PromptViewModel.StoredPromptEditResult
    ) {
        self.mode = mode
        self.onCreate = onCreate
        self.onSave = onSave
        _title = State(initialValue: mode.initialTitle)
        _content = State(initialValue: mode.initialContent)
    }

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var saveDisabled: Bool {
        guard !saveBlocked, !normalizedTitle.isEmpty else { return true }
        if case let .edit(prompt) = mode {
            return normalizedTitle == prompt.title && content == prompt.content
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.title)
                .font(fontPreset.titleFont)

            TextField("Prompt Title", text: $title)
                .font(fontPreset.standardFont)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $content)
                .font(fontPreset.standardFont)
                .accessibilityLabel("Prompt Content")
                .scrollContentBackground(.hidden)
                .frame(height: 300)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor).opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(fontPreset.captionFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(errorMessage)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveDisabled)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func save() {
        switch mode {
        case .create:
            switch onCreate(normalizedTitle, content) {
            case .created:
                dismiss()
            case .persistenceFailed:
                saveBlocked = false
                errorMessage = "This stored prompt could not be saved. Your draft is still open."
            }
        case let .edit(prompt):
            switch onSave(prompt, title, content) {
            case .updated, .unchanged:
                dismiss()
            case .targetMissing:
                saveBlocked = true
                errorMessage = "This stored prompt was deleted while the editor was open. Your changes were not saved."
            case .targetChanged:
                saveBlocked = true
                errorMessage = "This stored prompt changed while the editor was open. Close and reopen it before saving."
            case .targetProtected:
                saveBlocked = true
                errorMessage = "Built-in stored prompts cannot be edited."
            case .invalidTitle:
                errorMessage = "Enter a prompt title before saving."
            case .persistenceFailed:
                saveBlocked = false
                errorMessage = "This stored prompt could not be saved. Your changes remain in the editor."
            }
        }
    }
}

private struct AgentContextStoredPromptPreviewButton: View {
    let prompt: PromptViewModel.StoredPrompt
    let fontPreset: FontScalePreset

    @State private var showPreview = false

    var body: some View {
        Button {
            showPreview = true
        } label: {
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(SmallRoundButtonStyle(size: 24, iconSize: 11))
        .hoverTooltip("Preview prompt")
        .accessibilityLabel("Preview \(prompt.title)")
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
