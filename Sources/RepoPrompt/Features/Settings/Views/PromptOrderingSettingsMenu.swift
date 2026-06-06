//
//  PromptOrderingSettingsMenu.swift
//  RepoPrompt
//
//  Reworked 2025-04-16 - show greyed-out 2nd User Instructions row.
//

import RepoPromptCore
import SwiftUI

struct PromptOrderSettingsView: View {
    // MARK: - Dependencies

    //
    // `duplicateUserInstructionsAtTop` is owned by PromptViewModel, which now
    // persists the value through the JSON-backed GlobalSettingsStore. Binding
    // through the view model preserves packaging-invalidation side effects.
    @ObservedObject var promptViewModel: PromptViewModel
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    // MARK: - Hover state

    @State private var hoveredItem: String?

    private var duplicateUserInstructions: Bool {
        promptViewModel.duplicateUserInstructionsAtTop
    }

    // MARK: - View

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header — clarify scope
            VStack(alignment: .leading, spacing: 4) {
                Text("Copy Prompt Order")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .semibold))

                Text("Controls the order of sections in copied prompts and built-in chat packaging. Has no effect on Agent Mode, which uses its own context assembly.")
                    .font(fontPreset.subheadlineFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            // Section Order
            SettingSection(
                title: "Section Order",
                description: "Drag to reorder how sections appear in copied prompts"
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    reorderList
                        .frame(minHeight: 200)

                    HStack {
                        Spacer()
                        Button("Reset to Default") {
                            promptViewModel.promptSectionsOrder = PromptAssemblyBuilder.defaultSectionOrder
                            promptViewModel.savePromptSectionOrder()
                        }
                        .buttonStyle(CustomButtonStyle())
                    }
                    .padding(.top, 8)
                }
            }

            Divider()

            // Duplicate Instructions Option
            SettingSection(
                title: "Duplicate User Instructions",
                description: "Include user instructions at both the top and its ordered position"
            ) {
                SettingToggle(
                    title: "Enable duplicate at top",
                    description: "User instructions will appear at the beginning of the prompt as well as in its ordered position.",
                    isOn: $promptViewModel.duplicateUserInstructionsAtTop
                )
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sub-views / helpers

private extension PromptOrderSettingsView {
    /// --- 1. Generic row builder ------------------------------------------------
    func row(
        for section: PromptSection,
        movable: Bool = true,
        opacity: Double = 1.0,
        labelOverride: String? = nil
    ) -> some View {
        HStack {
            Text(labelOverride ?? section.displayName)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 16))
                .padding(.vertical, 8)

            Spacer()

            // Drag handle only for movable rows
            if movable {
                Image(systemName: "line.3.horizontal")
                    .foregroundColor(.secondary)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 14))
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    hoveredItem == section.displayName && movable
                        ? Color.gray.opacity(0.1)
                        : Color.clear
                )
        )
        .opacity(opacity)
        .onHover { isHovered in
            if movable {
                hoveredItem = isHovered ? section.displayName : nil
            }
        }
    }

    /// --- 2. List ---------------------------------------------------------------
    @ViewBuilder
    var reorderList: some View {
        // Greyed-out, non-movable duplicate row (if enabled)
        if duplicateUserInstructions {
            List {
                row(
                    for: .userInstructions,
                    movable: false,
                    opacity: 0.45,
                    labelOverride: "User Instructions (duplicate at top)"
                )
                .listRowSeparator(.hidden) // keeps it visually distinct

                // Regular, movable rows
                ForEach(promptViewModel.promptSectionsOrder, id: \.self) { section in
                    row(for: section)
                }
                .onMove(perform: promptViewModel.movePromptSection)
            }
            .listStyle(.plain)
            /*
             .background(
             	RoundedRectangle(cornerRadius: 8)
             		.stroke(Color.gray.opacity(0.2), lineWidth: 1)
             )
             */
        } else {
            List {
                // Regular, movable rows
                ForEach(promptViewModel.promptSectionsOrder, id: \.self) { section in
                    row(for: section)
                }
                .onMove(perform: promptViewModel.movePromptSection)
            }
            .listStyle(.plain)
            /*
             .background(
             	RoundedRectangle(cornerRadius: 8)
             		.stroke(Color.gray.opacity(0.2), lineWidth: 1)
             )
             */
        }
    }
}
