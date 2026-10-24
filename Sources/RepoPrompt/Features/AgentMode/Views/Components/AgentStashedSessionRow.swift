import AppKit
import RepoPromptDomainRuntime
import SwiftUI

// MARK: - Stashed Session Row

struct AgentStashedSessionRow: View {
    let stashed: StashedTab
    var createdByLabel: String?
    var onOpenCreator: (() -> Void)?
    var isSelected = false
    var showsSelectionPresentation = false
    var isInteractionEnabled = true
    var commandProgressKind: AgentSidebarBulkActionKind?
    let onSelectionGesture: (AgentSidebarSelectionGesture) -> AgentSidebarSelectionGestureDisposition
    let onRestore: () -> Void
    let onDelete: () -> Void
    let sessionIDCopyAction: AgentSidebarSessionIDCopyAction

    @State private var isHovered = false
    @State private var isRestoreHovered = false
    @State private var isDeleteHovered = false

    // MARK: - Context Menu Snapshot

    /// Snapshot of conditions controlling context menu item visibility, captured
    /// on hover to prevent NSRangeException from AppKit measuring stale item counts.
    private struct ContextMenuSnapshot {
        var isInteractionEnabled: Bool
        var showsSelectionPresentation: Bool
    }

    @State private var menuSnapshot = ContextMenuSnapshot(
        isInteractionEnabled: true,
        showsSelectionPresentation: false
    )

    /// Scaled layout metrics injected by the caller, which owns the App-layer font managers.
    /// Keeping the preset out of this file holds the row at plain SwiftUI/CoreGraphics types.
    let metrics: AgentStashedSessionRowMetrics

    private var allowsDirectMutations: Bool {
        isInteractionEnabled && !showsSelectionPresentation
    }

    private var restoreActionLabel: String {
        "Restore tab"
    }

    private var deleteActionLabel: String {
        "Delete stashed tab"
    }

    private var currentSelectionGesture: AgentSidebarSelectionGesture {
        var modifiers: AgentSidebarSelectionModifiers = []
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return AgentSidebarSelectionGesture(modifiers: modifiers)
    }

    private func handleRowTap() {
        guard isInteractionEnabled else { return }
        if onSelectionGesture(currentSelectionGesture) == .activate {
            onRestore()
        }
    }

    private func toggleSelection() {
        guard isInteractionEnabled else { return }
        _ = onSelectionGesture(.toggle)
    }

    var body: some View {
        HStack(spacing: metrics.rowSpacing) {
            if showsSelectionPresentation {
                Button(action: toggleSelection) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-6) // Keep the row layout unchanged around the larger hit target.
                .disabled(!isInteractionEnabled)
                .accessibilityLabel("\(isSelected ? "Deselect" : "Select") \(stashed.tab.name)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }

            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: metrics.leadingIconSize))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: metrics.titleVStackSpacing) {
                HStack(spacing: metrics.titlePinSpacing) {
                    Text(stashed.tab.name)
                        .font(metrics.titleFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let createdByLabel {
                        // Archived lanes have no live endpoint and no role mark — the eye family
                        // only ever means a live role — so the provenance affordance stays a plain
                        // neutral navigation button to the creator.
                        let tooltip = AgentOversightUICopy.createdByTooltip(
                            creator: createdByLabel
                        )
                        Button(action: { onOpenCreator?() }) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverTooltip(tooltip)
                        .accessibilityLabel(tooltip)
                    }
                    if stashed.tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: metrics.pinIconSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let commandProgressKind {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .allowsHitTesting(false)
                    .accessibilityLabel(commandProgressKind.rowProgressAccessibilityLabel)
            } else if isHovered, allowsDirectMutations {
                Button(action: onRestore) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 11))
                        .foregroundColor(isRestoreHovered ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isRestoreHovered = $0 }
                .hoverTooltip(restoreActionLabel)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(isDeleteHovered ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isDeleteHovered = $0 }
                .hoverTooltip(deleteActionLabel)
            }
        }
        .padding(.horizontal, metrics.rowHorizontalPadding)
        .padding(.vertical, metrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: metrics.rowMinHeight, alignment: .leading)
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                } else if isHovered {
                    RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
                        .stroke(Color(NSColor.systemGray).opacity(0.4), lineWidth: 1)
                }
            }
        )
        .contentShape(Rectangle())
        .contextMenu {
            if !menuSnapshot.showsSelectionPresentation {
                if menuSnapshot.isInteractionEnabled {
                    Button("Select chat", action: toggleSelection)
                    Divider()
                    Button(restoreActionLabel, action: onRestore)
                }
                Button(AgentSidebarSessionIDCopyAction.menuTitle) {
                    sessionIDCopyAction.perform()
                }
                .disabled(!sessionIDCopyAction.isEnabled)
                if menuSnapshot.isInteractionEnabled {
                    Divider()
                    Button(deleteActionLabel, role: .destructive, action: onDelete)
                }
            }
        }
        .onHover { hovered in
            isHovered = hovered
            if hovered {
                menuSnapshot = ContextMenuSnapshot(
                    isInteractionEnabled: isInteractionEnabled,
                    showsSelectionPresentation: showsSelectionPresentation
                )
            }
        }
        .onTapGesture(perform: handleRowTap)
        .focusable()
        .onKeyPress(.space) {
            toggleSelection()
            return .handled
        }
        .accessibilityLabel("\(stashed.tab.name), archived session")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAction(named: Text(isSelected ? "Deselect chat" : "Select chat"), toggleSelection)
    }
}

/// Everything the stashed row needs scaled for the caller's font preset, as plain values.
/// The preset-aware initializer lives next to the call site (`AgentSessionsSidebarView`) so this
/// file stays free of App-layer references.
struct AgentStashedSessionRowMetrics: Equatable {
    var rowMinHeight, rowHorizontalPadding, rowVerticalPadding, rowCornerRadius: CGFloat
    var rowSpacing, titlePinSpacing, titleVStackSpacing, leadingIconSize, pinIconSize: CGFloat
    var titleFont: Font
}
