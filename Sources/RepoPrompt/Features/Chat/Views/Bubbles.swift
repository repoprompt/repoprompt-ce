//
//  Bubbles.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-10-30.
//

import AppKit
import SwiftUI

// MARK: - Token Usage Indicator

private struct TokenUsageIndicator: View {
    let inputTokens: Int
    let outputTokens: Int
    let modelName: String?
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    // helper: 1 k = 1000 tokens, always 2 decimals
    private func format(_ tokens: Int) -> String {
        String(format: "%.2fk", Double(tokens) / 1000.0)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let modelName {
                Text(modelName)
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            Text("Tokens: \(format(inputTokens)) in | \(format(outputTokens)) out")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
    }
}

private struct FileSelectionIndicator: View {
    let message: AIChatMessage
    @ObservedObject var viewModel: OracleViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    @State private var isHovering = false
    @State private var showPopover = false

    // Helper: truncated path (keep last 3 segments)
    private func truncated(_ path: String, keep last: Int = 3) -> String {
        let comps = path.split(separator: "/")
        guard comps.count > last else { return path }
        let tail = comps.suffix(last).joined(separator: "/")
        return "…/" + tail
    }

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(fontPreset.captionFont)
                Text("\(message.selectedFileCount) file\(message.selectedFileCount == 1 ? "" : "s")")
                    .font(fontPreset.captionFont)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHovering
                            ? BubbleColors.mediumBlue
                            : BubbleColors.lightBlue.opacity(0.6)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(BubbleColors.borderBlue, lineWidth: 1)
                    .opacity(isHovering ? 1 : 0.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .hoverTooltip("View & restore file selection")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            FileSelectionPopover(message: message, viewModel: viewModel)
        }
    }

    // ────────────────────────────────────────────────
    // MARK: – Pop-over content

    /// ────────────────────────────────────────────────
    private struct FileSelectionPopover: View {
        let message: AIChatMessage
        @ObservedObject var viewModel: OracleViewModel
        @ObservedObject private var fontScale = FontScaleManager.shared
        private var fontPreset: FontScalePreset {
            fontScale.preset
        }

        /// Convenience
        private var paths: [String] {
            message.allowedFilePaths
        }

        /// Local cache that drives the check-mark UI
        @State private var selectedPaths = Set<String>()

        @Environment(\.colorScheme) private var scheme

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved file selection")
                        .font(fontPreset.headlineFont)
                    Text("The list below shows every file that was selected when this message was generated.")
                        .font(fontPreset.captionFont)
                        .foregroundColor(.secondary)

                    HStack {
                        Button("Add all to selection") {
                            Task { await viewModel.addFileSelection(from: message) }
                            selectedPaths = Set(paths) // mark all rows selected
                        }
                        .hoverTooltip("Keep current selection and add these files")

                        Button("Replace current selection") {
                            Task { await viewModel.restoreFileSelection(from: message) }
                            selectedPaths = Set(paths) // mark all rows selected
                        }
                        .hoverTooltip("Clear current selection and select these files instead")

                        Spacer()
                    }
                }
                .padding(8)
                .background(BubbleColors.lightBlue(colorScheme: scheme))

                Divider()

                // ───────── File list ─────────
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(paths, id: \.self) { path in
                            FileRow(
                                path: path,
                                isSelected: Binding(
                                    get: { selectedPaths.contains(path) },
                                    set: { newVal in
                                        if newVal {
                                            selectedPaths.insert(path)
                                        } else {
                                            selectedPaths.remove(path)
                                        }
                                    }
                                ),
                                fontPreset: fontPreset
                            ) { newVal in
                                // Relay change to view model
                                Task {
                                    await viewModel.toggleFileSelection(path: path, select: newVal)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: fontPreset.scaledClamped(400, max: 560))
            }
            .frame(width: fontPreset.scaledClamped(450, max: 600))
            .frame(minHeight: fontPreset.scaledMetric(200), maxHeight: fontPreset.scaledClamped(500, max: 660))
            .onAppear {
                // Initialise check-marks from actual selection state
                selectedPaths = Set(
                    paths.filter { viewModel.isFileSelected($0) }
                )
            }
        }

        // ─────────────────────────────────────────────────────────────
        // MARK: – Nested row view

        /// ─────────────────────────────────────────────────────────────
        private struct FileRow: View {
            let path: String
            @Binding var isSelected: Bool
            let fontPreset: FontScalePreset
            let onToggle: (Bool) -> Void

            var body: some View {
                Button(action: {
                    isSelected.toggle()
                    onToggle(isSelected)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(fontPreset.font)
                        Text(truncated(path))
                            .font(fontPreset.font)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            /// Helper to keep only the last 3 components
            private func truncated(_ path: String, keep last: Int = 3) -> String {
                let comps = path.split(separator: "/")
                guard comps.count > last else { return path }
                let tail = comps.suffix(last).joined(separator: "/")
                return "…/" + tail
            }
        }
    }
}

/// A compact circular progress indicator that places an SF-symbol
/// in the centre of the ring. The ring animates any time the
/// `progress` value changes. This implementation uses a slimmer ring
/// and a smaller centered icon for a more subtle look.
private struct MiniProgressRing: View {
    /// 0 – 1 (outside these bounds will be clamped)
    var progress: Double
    /// SF-symbol to draw inside the ring
    var iconSystemName: String
    /// Overall diameter
    var size: CGFloat = 14

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    /// Ring thickness – reduced for slimmer look
    private var lineWidth: CGFloat {
        size * 0.14
    }

    /// Icon size – slightly smaller to add inner padding
    private var iconSize: CGFloat {
        size * 0.48
    }

    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(lineWidth: lineWidth)
                .foregroundColor(Color.secondary.opacity(0.25))

            // Animated progress arc
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .foregroundColor(Color.accentColor)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: clampedProgress)

            // Centre icon
            Image(systemName: iconSystemName)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
        }
        .frame(width: size, height: size)
    }
}

struct MessageBubble: View {
    let message: AIChatMessage
    @ObservedObject var viewModel: OracleViewModel
    let isLatestMessage: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared

    // Flags for hover states
    @State private var isHoveringDelete = false
    @State private var isHoveringCopy = false
    @State private var showingDeleteConfirmation = false
    @State private var isHoveringFork = false // Add state for fork button hover
    @State private var isHoveringEdit = false // Add state for edit button hover

    // Edit mode state
    @State private var isEditingMessage = false
    @State private var editedText = ""

    /// For adaptive colors
    @Environment(\.colorScheme) private var colorScheme

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        // Stack them vertically, letting each sub-bubble
        // handle alignment to trailing/leading
        VStack(spacing: 0) {
            if message.isUser {
                userBubble
            } else {
                assistantMessage
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // The user bubble content
            Group {
                if isEditingMessage {
                    // Edit mode: show text editor
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack {
                            TextEditor(text: $editedText)
                                .font(fontPreset.font)
                                .frame(minHeight: 60)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)

                            // Invisible buttons to capture keyboard shortcuts
                            Button("") {
                                isEditingMessage = false
                                editedText = message.content
                            }
                            .keyboardShortcut(.escape, modifiers: [])
                            .hidden()

                            Button("") {
                                if !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Task {
                                        await viewModel.editAndResendMessage(messageId: message.id, newContent: editedText)
                                        isEditingMessage = false
                                    }
                                }
                            }
                            .keyboardShortcut(.return, modifiers: .command)
                            .hidden()
                        }

                        // Submit and Cancel buttons
                        HStack(spacing: 8) {
                            Button {
                                isEditingMessage = false
                                editedText = message.content
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Cancel")
                                    Text("⎋")
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                            }
                            .buttonStyle(CustomButtonStyle())

                            Button {
                                Task {
                                    await viewModel.editAndResendMessage(messageId: message.id, newContent: editedText)
                                    isEditingMessage = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Submit")
                                    Text("⌘⏎")
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                            }
                            .buttonStyle(CustomButtonStyle())
                            .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } else {
                    // Normal view mode
                    CollapsibleUserMessage(text: message.content)
                }
            }
            .padding(12)
            .background(BubbleColors.lightBlue)
            .cornerRadius(20)

            // Buttons below the bubble
            HStack { // Outer container to align trailing without forcing inner to expand
                HStack(spacing: 8) {
                    // Token indicator for user messages - always render to prevent layout shifts
                    Group {
                        if let inTok = message.promptTokens,
                           let outTok = message.completionTokens
                        {
                            TokenUsageIndicator(inputTokens: inTok, outputTokens: outTok, modelName: nil)
                        } else {
                            // Invisible placeholder with same height to maintain stable layout
                            Color.clear
                                .frame(width: 0, height: 20)
                        }
                    }

                    // Always show copy for user messages
                    CopyButtonOverlay(
                        message: message,
                        viewModel: viewModel,
                        showCopyButton: true,
                        isHoveringCopy: $isHoveringCopy,
                        showingDeleteConfirmation: $showingDeleteConfirmation
                    )

                    // Edit button for user messages
                    EditButtonOverlay(
                        isHoveringEdit: $isHoveringEdit,
                        isEditingMessage: $isEditingMessage,
                        editedText: $editedText,
                        messageContent: message.content,
                        isDisabled: viewModel.isSessionStreaming(viewModel.currentSessionID)
                    )

                    DeleteButtonOverlay(
                        message: message,
                        viewModel: viewModel,
                        isHoveringDelete: $isHoveringDelete,
                        showingConfirmation: $showingDeleteConfirmation
                    )
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(.thinMaterial)
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.bottom, 8)
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 0) { // Remove spacing between bubble and footer

            // main content - no background to avoid re-renders
            MessageBubbleContent(
                message: message,
                viewModel: viewModel,
                isLatestMessage: isLatestMessage
            )
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            // footer section - always rendered with fixed height to prevent layout thrashing
            footerBar
                .frame(height: fontPreset.scaledMetric(36))
                .opacity(message.isFinalized ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: message.isFinalized)
                .allowsHitTesting(message.isFinalized)
        }
        .padding(.bottom, 8)
    }

    private var footerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(.thinMaterial)
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)

                HStack(spacing: 8) {
                    CopyButtonOverlay(
                        message: message,
                        viewModel: viewModel,
                        showCopyButton: message.isFinalized,
                        isHoveringCopy: $isHoveringCopy,
                        showingDeleteConfirmation: $showingDeleteConfirmation
                    )

                    ForkButtonOverlay(
                        message: message,
                        viewModel: viewModel,
                        isHoveringFork: $isHoveringFork
                    )

                    DeleteButtonOverlay(
                        message: message,
                        viewModel: viewModel,
                        isHoveringDelete: $isHoveringDelete,
                        showingConfirmation: $showingDeleteConfirmation
                    )

                    if message.selectedFileCount > 0 {
                        FileSelectionIndicator(message: message, viewModel: viewModel)
                    }

                    if let inTok = message.promptTokens,
                       let outTok = message.completionTokens
                    {
                        TokenUsageIndicator(
                            inputTokens: inTok,
                            outputTokens: outTok,
                            modelName: message.modelName
                        )
                    } else if let modelName = message.modelName {
                        Text(modelName)
                            .font(fontPreset.captionFont)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Subviews

/// Add the new ForkButtonOverlay struct
private struct ForkButtonOverlay: View {
    let message: AIChatMessage
    @ObservedObject var viewModel: OracleViewModel
    @Binding var isHoveringFork: Bool

    var body: some View {
        Button(action: {
            Task {
                await viewModel.forkChatSession(from: message.id)
            }
        }) {
            Image(systemName: "arrow.triangle.branch") // Fork icon
                .foregroundColor(isHoveringFork ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal) // Use higher contrast
                .frame(width: 20, height: 20)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHoveringFork = hovering
            }
        }
        .hoverTooltip("Fork chat from this message")
    }
}

private struct BubbleContainer<Content: View>: View {
    let message: AIChatMessage
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(12)
        .background(message.isUser ? BubbleColors.userBubbleBackground : BubbleColors.assistantBubbleBackground)
        .cornerRadius(20)
    }
}

private struct EditButtonOverlay: View {
    @Binding var isHoveringEdit: Bool
    @Binding var isEditingMessage: Bool
    @Binding var editedText: String
    let messageContent: String
    let isDisabled: Bool

    var body: some View {
        Button(action: {
            editedText = messageContent
            isEditingMessage = true
        }) {
            Image(systemName: "pencil")
                .foregroundColor(isDisabled ? BubbleColors.copyIconNormal.opacity(0.3) : (isHoveringEdit ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isDisabled)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHoveringEdit = hovering
            }
        }
        .hoverTooltip(isDisabled ? "Cannot edit while AI is responding" : "Edit message")
    }
}

private struct DeleteButtonOverlay: View {
    let message: AIChatMessage
    @ObservedObject var viewModel: OracleViewModel
    @Binding var isHoveringDelete: Bool
    @Binding var showingConfirmation: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if showingConfirmation {
                // Confirm button
                Button(action: {
                    let id = message.id
                    Task {
                        await viewModel.removeMessage(id)
                    }
                }) {
                    Image(systemName: "checkmark")
                        .foregroundColor(BubbleColors.errorRed.opacity(0.8))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(PlainButtonStyle())
                .hoverTooltip("Confirm delete")

                // Cancel button
                Button(action: {
                    showingConfirmation = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(BubbleColors.neutralGray.opacity(0.8))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(PlainButtonStyle())
                .hoverTooltip("Cancel")

            } else {
                // Initial delete button
                Button(action: {
                    showingConfirmation = true
                }) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(isHoveringDelete ? BubbleColors.deleteIconHover : BubbleColors.deleteIconNormal)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHoveringDelete = hovering
                    }
                }
                .hoverTooltip("Delete message")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingConfirmation)
    }
}

private struct CopyButtonOverlay: View {
    let message: AIChatMessage
    @ObservedObject var viewModel: OracleViewModel
    let showCopyButton: Bool
    @Binding var isHoveringCopy: Bool
    @Binding var showingDeleteConfirmation: Bool

    var body: some View {
        if showCopyButton {
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    message.content,
                    forType: .string
                )

                // Cancel delete confirmation if active
                showingDeleteConfirmation = false
            }) {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(isHoveringCopy ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHoveringCopy = hovering
                }
            }
            .hoverTooltip("Copy message to clipboard")
        }
    }
}

// MARK: - Updated Reasoning Popover and Button

private struct ReasoningPopover: View {
    @Binding var reasoningContent: String
    var externalUpdateTick: Int = 0
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverHeader
            Divider()
            popoverContent
        }
    }

    // MARK: - ReasoningPopover (only popoverHeader changes)

    private var popoverHeader: some View {
        HStack {
            Text("AI Reasoning")
                .font(fontPreset.headlineFont)
                .padding()
            Spacer()
        }
        // .background(Color.blue.opacity(0.1))
    }

    private var popoverContent: some View {
        TextKitView(
            text: $reasoningContent,
            isEditable: false,
            isSpellCheckEnabled: false,
            externalUpdateTick: externalUpdateTick
        )
        .frame(width: fontPreset.scaledClamped(500, max: 660), height: fontPreset.scaledClamped(300, max: 440))
        .padding()
    }
}

private struct ReasoningButton: View {
    @Binding var reasoningContent: String
    let isStreaming: Bool
    var externalUpdateTick: Int = 0

    @State private var showReasoningPopover = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        Button(action: {
            showReasoningPopover.toggle()
        }) {
            buttonContent
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showReasoningPopover) {
            ReasoningPopover(
                reasoningContent: $reasoningContent,
                externalUpdateTick: externalUpdateTick
            )
        }
    }

    private var buttonContent: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain").font(fontPreset.captionFont)
            Text("Reasoning").font(fontPreset.captionFont)
            if isStreaming {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovering ? BubbleColors.mediumBlue : BubbleColors.lightBlue))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(BubbleColors.borderBlue, lineWidth: 1))
    }
}

private struct MessageBubbleContent: View {
    let message: AIChatMessage
    @ObservedObject var viewModel: OracleViewModel
    let isLatestMessage: Bool
    @State private var isCollapsed = true
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            reasoningButtonIfNeeded

            if message.content.isEmpty, !shouldShowReasoningButton, !message.isFinalized {
                loadingView
            } else if viewModel.debugMode {
                debugContent
            } else if message.isUser {
                userContent
            } else {
                assistantContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var reasoningButtonIfNeeded: some View {
        // Always render container to prevent layout shifts.
        Group {
            if shouldShowReasoningButton {
                let binding = viewModel.bindingForReasoningContent(of: message.id)
                ReasoningButton(
                    reasoningContent: binding,
                    isStreaming: isStreamingWithEmptyContent,
                    externalUpdateTick: viewModel.reasoningUpdateTick
                )
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
    }

    private var shouldShowReasoningButton: Bool {
        !message.isUser &&
            (
                !message.reasoningContent.isEmpty ||
                    !viewModel.ephemeralState.reasoningContent(for: message.id).isEmpty
            )
    }

    private var isStreamingWithEmptyContent: Bool {
        !message.isFinalized && message.content.isEmpty
    }

    private var shouldShowCollapsedAssistantView: Bool {
        !message.isUser && !isLatestMessage && message.content.lineEquivalentCount > 10
    }

    private var assistantPreview: String {
        message.content.firstLineEquivalents(10)
    }

    private var loadingView: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
            .scaleEffect(0.7)
            .frame(height: 20)
    }

    private var debugContent: some View {
        CodeBlock(
            content: message.content,
            allowTextInteraction: isLatestMessage && message.isFinalized
        )
    }

    private var userContent: some View {
        Text(message.content)
            .font(fontPreset.font)
            .textSelection(.enabled)
            .allowsHitTesting(isLatestMessage && message.isFinalized)
    }

    @ViewBuilder
    private var assistantContent: some View {
        if shouldShowCollapsedAssistantView {
            collapsibleAssistantContent
        } else {
            markdownAssistantContent
        }
    }

    private var collapsibleAssistantContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCollapsed {
                Text(assistantPreview)
                    .font(fontPreset.font)
                    .textSelection(.enabled)
                    .allowsHitTesting(message.isFinalized)
                    .lineLimit(10)
            } else {
                markdownAssistantContent
            }

            Button {
                if isCollapsed {
                    isCollapsed = false
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isCollapsed = true
                    }
                }
            } label: {
                Text(isCollapsed ? "Show more…" : "Show less")
                    .font(fontPreset.subheadlineFont)
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    private var markdownAssistantContent: some View {
        MarkdownTextView(
            text: message.content,
            isMarkdown: true,
            allowInteraction: message.isFinalized
        )
        .equatable()
    }
}

private extension String {
    var lineEquivalentCount: Int {
        guard !isEmpty else { return 0 }
        return split(separator: "\n", omittingEmptySubsequences: false).count
    }

    func firstLineEquivalents(_ limit: Int) -> String {
        split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(limit)
            .joined(separator: "\n")
    }
}

// MARK: - Additional Views

/// A small bubble view for displaying errors (e.g. unloadable files).
private struct ErrorMessagesBubbleView: View {
    let errors: [String]
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(errors, id: \.self) { errorMsg in
                Text(errorMsg)
                    .font(fontPreset.captionFont)
            }
        }
        .padding(8)
        .background(BubbleColors.errorBackground)
        .cornerRadius(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: – Content-sized text view (reports both width and height)

// MARK: - Shared Components

// CollapsibleUserMessage and ContentSizedTextView are now in Common/CollapsibleUserMessage.swift
