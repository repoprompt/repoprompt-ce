import RepoPromptFileSystem

//
//  MentionSuggestionView.swift
//  RepoPrompt
//
//  SwiftUI replacement for the AppKit-based NSTableView suggestion list.
//  Hosted inside the borderless SuggestionWindow via NSHostingView.
//

import SwiftUI

// MARK: - Observable model bridging AppKit → SwiftUI

/// Bridges the `SuggestionWindow`'s mutable state into SwiftUI's observation
/// system.  The AppKit window code writes to `suggestions` / `highlightedIndex`,
/// and the SwiftUI `MentionSuggestionListView` reacts automatically.
@MainActor
final class MentionSuggestionListModel: ObservableObject {
    @Published var suggestions: [MentionSuggestion] = []
    @Published var highlightedIndex: Int = 0
    @Published var visibleRowLimit: Int = 5

    /// Called when the user clicks a row. The overlay controller uses it to
    /// make that row the current keyboard selection.
    var onRowClicked: ((Int) -> Void)?
}

// MARK: - Row view

struct MentionSuggestionRowView: View {
    let suggestion: MentionSuggestion
    let isHighlighted: Bool
    var onTap: (() -> Void)?

    private var rowHeight: CGFloat {
        FontScalePreset.current.rowHeight + 4
    }

    static func accessibilityTraits(isHighlighted: Bool) -> AccessibilityTraits {
        isHighlighted ? .isSelected : []
    }

    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)

            // Text content
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.displayName)
                    .font(.system(size: FontScalePreset.current.rawValue))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: max(FontScalePreset.current.rawValue - 3, 9)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            // Folder drill-down indicator
            if suggestion.kind == .folder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHighlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(Self.accessibilityTraits(isHighlighted: isHighlighted))
        .onTapGesture {
            onTap?()
        }
    }

    // MARK: - Icon helpers

    private var iconName: String {
        switch suggestion.kind {
        case .folder: "folder.fill"
        case .file: "doc.text.fill"
        case .skill: "terminal"
        }
    }

    private var iconColor: Color {
        switch suggestion.kind {
        case .folder: .blue
        case .file: Color(.secondaryLabelColor)
        case .skill: Color(.secondaryLabelColor)
        }
    }
}

// MARK: - List view

struct MentionSuggestionListView: View {
    @ObservedObject var model: MentionSuggestionListModel

    var body: some View {
        if model.suggestions.isEmpty {
            emptyState
        } else {
            suggestionList
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))
            Text("No results found")
                .foregroundStyle(.secondary)
                .font(.system(size: FontScalePreset.current.rawValue))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Suggestion list

    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: model.suggestions.count > model.visibleRowLimit) {
                VStack(spacing: 2) {
                    ForEach(
                        Array(model.suggestions.enumerated()),
                        id: \.element.id
                    ) { index, suggestion in
                        MentionSuggestionRowView(
                            suggestion: suggestion,
                            isHighlighted: index == model.highlightedIndex,
                            onTap: { model.onRowClicked?(index) }
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 4)
            }
            .contentMargins(.vertical, 4, for: .scrollContent)
            .onChange(of: model.highlightedIndex) { _, newValue in
                proxy.scrollTo(newValue)
            }
            .onChange(of: model.suggestions) { _, _ in
                proxy.scrollTo(model.highlightedIndex)
            }
        }
    }
}
