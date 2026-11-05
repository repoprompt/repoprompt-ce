import SwiftUI

// Filter tabs and search field above the session list.
//
// Tabs choose the dataset and search narrows it, so search sits directly above the results it
// filters. The tab track, the search field and the row backgrounds share one gutter, so they have
// identical edges. Section headers, the search text and row titles share a second, inner inset.
// Spacing is tighter inside the header than between the header and the list.
//
// SEARCH-HELPER: sidebar header, sidebar search, sidebar tabs, collapse all threads.

/// The sidebar's layout grid, shared by the header, section headers and rows so they cannot drift.
@MainActor
struct AgentSidebarMetrics {
    /// The unified toolbar is 52pt tall and centers its 28pt buttons, leaving this much empty
    /// toolbar under them. The header's top inset absorbs it, so the visible gap is the intended one.
    private static let titlebarSlackBelowButtons: CGFloat = 12

    let preset: FontScalePreset

    /// The status plate leading each row. Section header chevrons and the search icon use this slot
    /// too, so all of them line up in one column.
    static let statusPlateSize: CGFloat = 16

    /// The shared gutter: sidebar edge to the tab track, search field and row backgrounds.
    var gutter: CGFloat {
        preset.scaledClamped(10, max: 14)
    }

    /// Row background edge to its content.
    var rowHorizontalPadding: CGFloat {
        preset.scaledClamped(10, max: 14)
    }

    /// Between a row's status plate and its title.
    var rowSpacing: CGFloat {
        preset.scaledClamped(8, max: 11)
    }

    /// Row background edge to row title text, measured inside the gutter. Section headers use it too.
    var rowTextInset: CGFloat {
        rowHorizontalPadding + Self.statusPlateSize + rowSpacing
    }

    /// Above the first section header in the list.
    var firstSectionHeaderTopPadding: CGFloat {
        preset.scaledClamped(2, max: 3)
    }

    /// Matches the rows' minimum height.
    var searchHeight: CGFloat {
        preset.scaledClamped(28, min: 28, max: 38)
    }

    var trackHeight: CGFloat {
        preset.scaledClamped(26, min: 26, max: 34)
    }

    /// Gap between the track and its selected pill. Both are capsules, so the pill's radius is
    /// always the track's radius minus this inset.
    var trackInset: CGFloat {
        preset.scaledClamped(2, min: 2, max: 3)
    }

    var segmentHeight: CGFloat {
        trackHeight - trackInset * 2
    }

    /// Titlebar buttons to tabs: 8pt visible.
    var topInset: CGFloat {
        preset.scaledClamped(8, max: 11) - Self.titlebarSlackBelowButtons
    }

    /// Tabs to search.
    var controlSpacing: CGFloat {
        preset.scaledClamped(8, max: 11)
    }

    /// Search to the first section header: 16pt visible, including that header's own top padding.
    var bottomInset: CGFloat {
        preset.scaledClamped(16, max: 22) - firstSectionHeaderTopPadding
    }
}

// MARK: - Search

struct AgentSidebarSearchField: View {
    @Binding var text: String
    let placeholder: String

    @FocusState private var isFocused: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var metrics: AgentSidebarMetrics {
        AgentSidebarMetrics(preset: fontScale.preset)
    }

    var body: some View {
        HStack(spacing: metrics.rowSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: fontScale.preset.scaledClamped(12, max: 16), weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: AgentSidebarMetrics.statusPlateSize)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(fontScale.preset.swiftUIFont(sizeAtNormal: 13))
                .focused($isFocused)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: fontScale.preset.scaledClamped(12, max: 16)))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, metrics.rowHorizontalPadding)
        .frame(height: metrics.searchHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color(NSColor.labelColor).opacity(0.05))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.7 : 0), lineWidth: 1)
        )
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { isFocused = true }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

// MARK: - Tabs

struct AgentSidebarTabStrip: View {
    let selection: AgentSidebarTab
    let onSelect: (AgentSidebarTab) -> Void

    @Namespace private var selectionNamespace
    @ObservedObject private var fontScale = FontScaleManager.shared

    var body: some View {
        let metrics = AgentSidebarMetrics(preset: fontScale.preset)
        let tabs = AgentSidebarTab.allCases
        AgentSidebarTabTrackLayout {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                AgentSidebarTabButton(
                    tab: tab,
                    isSelected: tab == selection,
                    // No divider touches the selected pill.
                    showsLeadingDivider: index > 0 && tab != selection && tabs[index - 1] != selection,
                    selectionNamespace: selectionNamespace,
                    action: { onSelect(tab) }
                )
            }
        }
        .padding(metrics.trackInset)
        .frame(height: metrics.trackHeight)
        .background(Capsule(style: .continuous).fill(Color(NSColor.labelColor).opacity(0.05)))
        // Scoped to the strip: only the selection pill animates, never the list it filters.
        .animation(.easeInOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show sessions")
    }
}

/// Fills the track while sizing segments to their labels: each segment gets its label's width plus
/// an equal share of what is left, so short labels do not float and long ones are not cramped.
private struct AgentSidebarTabTrackLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? sizes.reduce(0) { $0 + $1.width },
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard !subviews.isEmpty else { return }
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let share = (bounds.width - widths.reduce(0, +)) / CGFloat(subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            let segmentWidth = max(0, width + share)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: segmentWidth, height: bounds.height)
            )
            x += segmentWidth
        }
    }
}

private struct AgentSidebarTabButton: View {
    let tab: AgentSidebarTab
    let isSelected: Bool
    let showsLeadingDivider: Bool
    let selectionNamespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false
    @ObservedObject private var fontScale = FontScaleManager.shared

    private var metrics: AgentSidebarMetrics {
        AgentSidebarMetrics(preset: fontScale.preset)
    }

    private var foreground: Color {
        if isSelected || isHovered {
            return Color(NSColor.labelColor)
        }
        return Color(NSColor.secondaryLabelColor)
    }

    var body: some View {
        Button(action: action) {
            // One weight in every state, so selecting a tab never shifts its neighbours.
            Text(tab.title)
                .font(fontScale.preset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(foreground)
                .padding(.horizontal, metrics.rowHorizontalPadding)
                .frame(maxWidth: .infinity)
                .frame(height: metrics.segmentHeight)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color(NSColor.labelColor).opacity(0.14))
                            .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(NSColor.labelColor).opacity(showsLeadingDivider ? 0.12 : 0))
                .frame(width: 1, height: metrics.segmentHeight / 2)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .hoverTooltip(tab.helpText, .bottom)
        .accessibilityLabel(tab.title)
        .accessibilityHint(tab.helpText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Collapse

/// Collapse or expand every group in the selected tab. Lives in the titlebar because it controls the
/// list, not search. When nothing can fold it dims rather than disappears, so the titlebar cluster
/// never reflows and the reason is one hover away.
struct AgentSidebarCollapseAllButton: View {
    let state: AgentModeViewModel.SidebarCollapseAllState
    let tab: AgentSidebarTab
    let isSearching: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var clickTick = 0

    private var isAvailable: Bool {
        state != .unavailable
    }

    private var tooltip: String {
        switch state {
        case .canCollapse:
            "Collapse all \(tab.collapsibleNoun)"
        case .canExpand:
            "Expand all \(tab.collapsibleNoun)"
        case .unavailable:
            isSearching ? "Clear search to collapse \(tab.collapsibleNoun)" : "No \(tab.collapsibleNoun) to collapse here"
        }
    }

    var body: some View {
        Button {
            clickTick &+= 1
            action()
        } label: {
            Image(systemName: state == .canExpand ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary.opacity(!isAvailable ? 0.3 : isHovered ? 1.0 : 0.7))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.down, value: clickTick)
        }
        .buttonStyle(TitlebarAccessoryButtonStyle(isHovering: isHovered && isAvailable))
        .disabled(!isAvailable)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .hoverTooltip(tooltip, .bottom)
        .accessibilityLabel(tooltip)
        .animation(.easeInOut(duration: 0.15), value: state)
    }
}
