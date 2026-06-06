import AppKit
import SwiftUI

/// A simple prompt model for context builder custom instructions.
/// Stored globally in a JSON file, with per-tab selection.
struct ContextBuilderPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var isPinned: Bool

    init(id: UUID = UUID(), title: String, content: String, isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.content = content
        self.isPinned = isPinned
    }

    /// Custom decoder for backward compatibility with existing JSON that lacks isPinned
    private enum CodingKeys: String, CodingKey {
        case id, title, content, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

// MARK: - Global Storage

/// Manages reading and writing context builder prompts as JSON
/// in the app's Application Support directory.
class ContextBuilderPromptStorage: ObservableObject {
    static let shared = ContextBuilderPromptStorage()
    static let builtInPrompts: [ContextBuilderPrompt] = [
        ContextBuilderPrompt(
            id: UUID(uuidString: "C2F4A6D9-7C9E-4C2B-9B2B-41A4C49F0D2B")!,
            title: "Interview",
            content: """
            Use the ask user question tool to interview me before completing this and writing up the enhanced instructions on exactly what we're going to do. Feel free to ask me multiple detailed questions.

            The idea is that we should explore the task space so that we ensure that the user is aligned and we really understand what he wants before we generate a plan.
            """
        )
    ]

    private let filename = "ContextBuilderPrompts.json"
    private let builtInPinnedDefaultsKey = "ContextBuilderBuiltInPinnedPromptIDs"
    private static let queue = DispatchQueue(label: "com.pvncher.repoprompt.ContextBuilderPromptStorageQueue")

    @Published private(set) var prompts: [ContextBuilderPrompt] = []
    @Published private(set) var builtInPinnedPromptIDs: Set<UUID> = []
    var builtInPrompts: [ContextBuilderPrompt] {
        Self.builtInPrompts.map { basePrompt in
            var prompt = basePrompt
            prompt.isPinned = builtInPinnedPromptIDs.contains(basePrompt.id)
            return prompt
        }
    }

    var allPrompts: [ContextBuilderPrompt] {
        builtInPrompts + prompts
    }

    private var fileURL: URL {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let appSupportFolder = supportDir.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appSupportFolder,
            withIntermediateDirectories: true
        )

        return appSupportFolder.appendingPathComponent(filename)
    }

    private init() {
        loadPrompts()
        loadBuiltInPinnedPromptIDs()
    }

    /// Load prompts from disk
    func loadPrompts() {
        Self.queue.sync {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                DispatchQueue.main.async {
                    self.prompts = []
                }
                return
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let loaded = try JSONDecoder().decode([ContextBuilderPrompt].self, from: data)
                DispatchQueue.main.async {
                    self.prompts = loaded
                }
            } catch {
                print("⚠️ Failed to load context builder prompts: \(error)")
                DispatchQueue.main.async {
                    self.prompts = []
                }
            }
        }
    }

    /// Save prompts to disk
    func savePrompts(_ newPrompts: [ContextBuilderPrompt]) {
        DispatchQueue.main.async {
            self.prompts = newPrompts
        }

        Self.queue.async {
            do {
                let data = try JSONEncoder().encode(newPrompts)
                try data.write(to: self.fileURL, options: .atomicWrite)
            } catch {
                print("⚠️ Failed to save context builder prompts: \(error)")
            }
        }
    }

    /// Add a new prompt
    func addPrompt(_ prompt: ContextBuilderPrompt) {
        var updated = prompts
        updated.append(prompt)
        savePrompts(updated)
    }

    /// Update an existing prompt
    func updatePrompt(_ prompt: ContextBuilderPrompt) {
        var updated = prompts
        if let index = updated.firstIndex(where: { $0.id == prompt.id }) {
            updated[index] = prompt
            savePrompts(updated)
        }
    }

    /// Remove a prompt
    func removePrompt(_ prompt: ContextBuilderPrompt) {
        var updated = prompts
        updated.removeAll { $0.id == prompt.id }
        savePrompts(updated)
    }

    /// Get prompt text for selected IDs in XML meta prompt format
    func promptText(for selectedIDs: Set<UUID>) -> String? {
        Self.promptText(for: selectedIDs, in: allPrompts)
    }

    static func promptText(
        for selectedIDs: Set<UUID>,
        in orderedPrompts: [ContextBuilderPrompt]
    ) -> String? {
        let selected = orderedPrompts.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return nil }

        return selected
            .map { "<meta prompt=\"\($0.title)\">\n\($0.content)\n</meta prompt>" }
            .joined(separator: "\n\n")
    }

    // MARK: - Pinned Prompts

    /// Toggle the pinned state of a prompt
    func togglePinned(_ prompt: ContextBuilderPrompt) -> Bool {
        if isBuiltInPrompt(prompt.id) {
            let isPinned = builtInPinnedPromptIDs.contains(prompt.id)
            let updatedIsPinned = !isPinned
            setBuiltInPinned(updatedIsPinned, for: prompt.id)
            return updatedIsPinned
        } else {
            var updated = prompt
            updated.isPinned.toggle()
            updatePrompt(updated)
            return updated.isPinned
        }
    }

    /// Set the pinned state for a prompt by ID
    func setPinned(_ isPinned: Bool, for id: UUID) {
        if isBuiltInPrompt(id) {
            setBuiltInPinned(isPinned, for: id)
            return
        }
        guard let prompt = prompts.first(where: { $0.id == id }) else { return }
        var updated = prompt
        updated.isPinned = isPinned
        updatePrompt(updated)
    }

    /// Returns IDs of all pinned prompts (for auto-selecting in new tabs)
    var pinnedPromptIDs: [UUID] {
        let customPinned = prompts.filter(\.isPinned).map(\.id)
        let builtInPinned = Array(builtInPinnedPromptIDs)
        return builtInPinned + customPinned
    }

    private func isBuiltInPrompt(_ id: UUID) -> Bool {
        Self.builtInPrompts.contains { $0.id == id }
    }

    private func loadBuiltInPinnedPromptIDs() {
        let storedIDs = UserDefaults.standard.stringArray(forKey: builtInPinnedDefaultsKey) ?? []
        let parsedIDs = storedIDs.compactMap { UUID(uuidString: $0) }
        builtInPinnedPromptIDs = Set(parsedIDs)
    }

    private func setBuiltInPinned(_ isPinned: Bool, for id: UUID) {
        if isPinned {
            builtInPinnedPromptIDs.insert(id)
        } else {
            builtInPinnedPromptIDs.remove(id)
        }
        let storedIDs = builtInPinnedPromptIDs.map(\.uuidString)
        UserDefaults.standard.set(storedIDs, forKey: builtInPinnedDefaultsKey)
    }
}

// MARK: - Overlay View

/// Overlay for managing context builder prompts.
/// A minimal single-pane UI for custom prompts that customize context builder runs.
struct ContextBuilderPromptsOverlay: View {
    @Binding var isVisible: Bool
    @Binding var selectedPromptIDs: Set<UUID>
    @ObservedObject var storage: ContextBuilderPromptStorage = .shared

    @State private var showPromptEditor = false
    @State private var editingPrompt: ContextBuilderPrompt?
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var panelWidth: CGFloat {
        480 * fontPreset.scaleFactor
    }

    private var panelMaxHeight: CGFloat {
        450 * fontPreset.scaleFactor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            promptsList
        }
        .padding(16 * fontPreset.scaleFactor)
        .frame(width: panelWidth)
        .frame(maxHeight: panelMaxHeight, alignment: .top)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12 * fontPreset.scaleFactor)
        .shadow(radius: 10)
        .sheet(isPresented: $showPromptEditor) {
            ContextBuilderPromptEditor(
                isVisible: $showPromptEditor,
                editingPrompt: $editingPrompt,
                storage: storage
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Context Builder Prompts")
                    .font(fontPreset.headlineFont.weight(.medium))
                Text("Select prompts to include when running context builder.")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("New") {
                editingPrompt = nil
                showPromptEditor = true
            }
            .buttonStyle(CustomButtonStyle())

            Button(action: { isVisible = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private var promptsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !storage.builtInPrompts.isEmpty {
                    promptSectionHeader("Built-in")
                    ForEach(storage.builtInPrompts) { prompt in
                        ContextBuilderPromptRow(
                            prompt: prompt,
                            isSelected: selectedPromptIDs.contains(prompt.id),
                            onToggle: { togglePrompt(prompt) },
                            onTogglePin: { togglePinAndSelect(prompt) },
                            onEdit: {},
                            onDelete: {},
                            showsPinAction: true,
                            showsCopyAction: true,
                            showsEditAction: false,
                            showsDeleteAction: false
                        )
                    }
                }

                promptSectionHeader("Custom")

                if storage.prompts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("No custom prompts yet")
                            .font(fontPreset.font)
                            .foregroundColor(.secondary)
                        Text("Add prompts to customize how context builder explores your codebase.")
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    // Show pinned prompts first, then unpinned
                    let sortedPrompts = storage.prompts.sorted { lhs, rhs in
                        if lhs.isPinned != rhs.isPinned {
                            return lhs.isPinned // pinned first
                        }
                        return false // preserve original order within groups
                    }
                    ForEach(sortedPrompts) { prompt in
                        ContextBuilderPromptRow(
                            prompt: prompt,
                            isSelected: selectedPromptIDs.contains(prompt.id),
                            onToggle: { togglePrompt(prompt) },
                            onTogglePin: { togglePinAndSelect(prompt) },
                            onEdit: {
                                editingPrompt = prompt
                                showPromptEditor = true
                            },
                            onDelete: {
                                storage.removePrompt(prompt)
                                selectedPromptIDs.remove(prompt.id)
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func promptSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(fontPreset.captionFont.weight(.semibold))
            .foregroundColor(.secondary)
    }

    private func togglePrompt(_ prompt: ContextBuilderPrompt) {
        if selectedPromptIDs.contains(prompt.id) {
            selectedPromptIDs.remove(prompt.id)
        } else {
            selectedPromptIDs.insert(prompt.id)
        }
    }

    private func togglePinAndSelect(_ prompt: ContextBuilderPrompt) {
        let isPinned = storage.togglePinned(prompt)
        if isPinned, !selectedPromptIDs.contains(prompt.id) {
            selectedPromptIDs.insert(prompt.id)
        }
    }
}

/// Row view for a single context builder prompt.
struct ContextBuilderPromptRow: View {
    let prompt: ContextBuilderPrompt
    let isSelected: Bool
    let onToggle: () -> Void
    let onTogglePin: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var showsPinAction: Bool = true
    var showsCopyAction: Bool = true
    var showsEditAction: Bool = true
    var showsDeleteAction: Bool = true

    @State private var isRowHovering = false
    @State private var isCopying = false
    @State private var hoveringButton: String?
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isSelected ? (isRowHovering ? "minus.circle.fill" : "checkmark.circle.fill") : "plus.circle")
                    .foregroundColor(isSelected ? .orange : .primary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(PlainButtonStyle())

            // Pin indicator (always visible when pinned)
            if prompt.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .help("Pinned - auto-selected in new tabs")
            }

            Text(prompt.title)
                .font(fontPreset.font)
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            if showsPinAction || showsCopyAction || showsEditAction || showsDeleteAction {
                HStack(spacing: 8) {
                    // Pin/Unpin button
                    if showsPinAction {
                        Button(action: onTogglePin) {
                            Image(systemName: prompt.isPinned ? "pin.slash" : "pin")
                                .foregroundColor(hoveringButton == "pin" ? .orange : (prompt.isPinned ? .orange : .primary))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveringButton = hovering ? "pin" : nil
                        }
                        .help(prompt.isPinned ? "Unpin from new tabs" : "Pin to auto-select in new tabs")
                    }

                    if showsCopyAction {
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt.content, forType: .string)
                            isCopying = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                isCopying = false
                            }
                        }) {
                            Image(systemName: isCopying ? "checkmark" : "doc.on.doc")
                                .foregroundColor(hoveringButton == "copy" ? .blue : .primary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveringButton = hovering ? "copy" : nil
                        }
                    }

                    if showsEditAction {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .foregroundColor(hoveringButton == "edit" ? .blue : .primary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveringButton = hovering ? "edit" : nil
                        }
                    }

                    if showsDeleteAction {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .foregroundColor(hoveringButton == "delete" ? .red : .secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoveringButton = hovering ? "delete" : nil
                        }
                    }
                }
                .opacity(isRowHovering ? 1 : 0)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.orange.opacity(0.1) : (isRowHovering ? Color.secondary.opacity(0.1) : Color.clear))
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isRowHovering = hovering
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

/// Editor sheet for creating or editing a context builder prompt.
struct ContextBuilderPromptEditor: View {
    @Binding var isVisible: Bool
    @Binding var editingPrompt: ContextBuilderPrompt?
    @ObservedObject var storage: ContextBuilderPromptStorage

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var externalUpdateTick: Int = 0
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(editingPrompt == nil ? "New Prompt" : "Edit Prompt")
                .font(fontPreset.titleFont)

            TextField("Prompt Title", text: $title)
                .font(fontPreset.font)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            TextKitView(text: $content, externalUpdateTick: externalUpdateTick)
                .frame(height: 250)
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .overlay(
                    Text(" Enter custom instructions for context builder...")
                        .font(fontPreset.font)
                        .foregroundColor(.secondary)
                        .opacity(content.isEmpty ? 1 : 0)
                        .allowsHitTesting(false)
                        .padding(10),
                    alignment: .topLeading
                )

            Text("These instructions guide the context builder when exploring your codebase.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)

            HStack {
                Button(action: { isVisible = false }) {
                    Text("Cancel")
                }
                .buttonStyle(CustomButtonStyle())

                Button(action: savePrompt) {
                    Text("Save")
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .shadow(radius: 10)
        .onAppear {
            if let editing = editingPrompt {
                title = editing.title
                content = editing.content
            } else {
                title = ""
                content = ""
            }
            externalUpdateTick &+= 1
        }
    }

    private func savePrompt() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        if let editing = editingPrompt {
            // Update existing prompt
            let updated = ContextBuilderPrompt(id: editing.id, title: trimmedTitle, content: content)
            storage.updatePrompt(updated)
        } else {
            // Add new prompt
            let newPrompt = ContextBuilderPrompt(title: trimmedTitle, content: content)
            storage.addPrompt(newPrompt)
        }

        isVisible = false
    }
}

// MARK: - Compact Button for ContextBuilderView

/// A compact button that shows the prompts overlay and selected count.
struct ContextBuilderPromptsButton: View {
    @Binding var selectedPromptIDs: Set<UUID>
    @Binding var showOverlay: Bool
    @ObservedObject var storage: ContextBuilderPromptStorage = .shared
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var selectedCount: Int {
        // Only count IDs that still exist in storage
        selectedPromptIDs.count(where: { id in
            storage.allPrompts.contains { $0.id == id }
        })
    }

    var body: some View {
        Button(action: { showOverlay = true }) {
            HStack(spacing: 4) {
                Image(systemName: "text.quote")
                    .font(.caption)
                if selectedCount > 0 {
                    Text("\(selectedCount)")
                        .font(fontPreset.captionFont)
                } else {
                    Text("Prompts")
                        .font(fontPreset.captionFont)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selectedCount > 0 ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.1))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selectedCount > 0 ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(selectedCount > 0 ? "\(selectedCount) prompt\(selectedCount == 1 ? "" : "s") selected" : "Add custom prompts")
    }
}
