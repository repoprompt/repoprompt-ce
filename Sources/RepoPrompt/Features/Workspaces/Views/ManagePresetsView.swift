//
//  ManagePresetsView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-01.
//

import SwiftUI

struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .accentColor : .primary)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0))
                    .opacity(configuration.isPressed ? 1.0 : 0.0)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ManagePresetsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManagerViewModel

    /// Whether this sheet is currently visible
    @Binding var isPresented: Bool

    // NEW: Optional param to control close button visibility
    var showCloseButton: Bool = true

    /// The workspace whose presets we are editing
    let workspace: WorkspaceModel

    @State private var presetBeingRenamed: WorkspacePreset?
    @State private var renameField: String = ""
    @State private var refreshTrigger = UUID()
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    /// Get the current workspace from workspaceManager to ensure we have the latest data
    private var currentWorkspace: WorkspaceModel? {
        workspaceManager.workspaces.first(where: { $0.id == workspace.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    existingPresetsSection
                }
                .padding(16)
            }
        }
        .frame(
            minWidth: showCloseButton ? fontPreset.scaledMetric(500) : 0,
            minHeight: showCloseButton ? fontPreset.scaledMetric(400) : 0
        )
        .sheet(item: $presetBeingRenamed) { p in
            renameSheet(preset: p)
        }
        .id(refreshTrigger) // Force refresh when this changes
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manage Presets")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .semibold))
                Text("Edit, reorder or remove your workspace presets")
                    .foregroundColor(.secondary)
                    .font(fontPreset.subheadlineFont)
            }
            Spacer()

            // Only show the x close button if showCloseButton is true
            if showCloseButton {
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Existing Presets

    private var existingPresetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Existing Presets for \(workspace.name)")
                .font(fontPreset.headlineFont)

            VStack(alignment: .leading, spacing: 6) {
                Text("Presets allow you to quickly switch between different sets of selected files.")
                    .foregroundColor(.secondary)
                Text("Use keyboard shortcuts ⌘⌥1 through ⌘⌥9 to switch between the first 9 presets.")
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)

            Divider()
                .padding(.bottom, 8)

            // Use currentWorkspace to get the most up-to-date presets
            if let presets = currentWorkspace?.presets, !presets.isEmpty {
                // Use LazyVStack for better performance with many presets
                LazyVStack(spacing: 12) {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                        let isFirst = index == 0
                        let isLast = index >= presets.count - 1

                        OptimizedPresetRow(
                            preset: preset,
                            index: index,
                            isFirst: isFirst,
                            isLast: isLast,
                            onMoveUp: {
                                movePresetUp(id: preset.id, at: index)
                            },
                            onMoveDown: {
                                movePresetDown(id: preset.id, at: index)
                            },
                            onSwitch: {
                                Task {
                                    await workspaceManager.applyPreset(preset.id)
                                    isPresented = false
                                }
                            },
                            onRename: {
                                presetBeingRenamed = preset
                                renameField = preset.name
                            },
                            onDelete: {
                                workspaceManager.deletePreset(preset, from: workspace)
                                refreshTrigger = UUID()
                            }
                        )
                    }
                }
            } else {
                Text("No presets found. Create a new preset from the Presets menu.")
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Preset Reordering

    /// Move preset up in the list
    private func movePresetUp(id: UUID, at index: Int) {
        guard index > 0, let workspace = currentWorkspace else { return }
        movePreset(id: id, in: workspace, fromIndex: index, toIndex: index - 1)
    }

    /// Move preset down in the list
    private func movePresetDown(id: UUID, at index: Int) {
        guard let workspace = currentWorkspace,
              index < workspace.presets.count - 1 else { return }
        movePreset(id: id, in: workspace, fromIndex: index, toIndex: index + 1)
    }

    private func movePreset(id: UUID, in workspace: WorkspaceModel, fromIndex: Int, toIndex: Int) {
        // Get a copy of the presets array
        var presets = workspace.presets

        // Perform the reordering by moving the preset from the current to the new position
        let preset = presets.remove(at: fromIndex)
        presets.insert(preset, at: toIndex)

        // Update the workspace with the reordered presets
        // This would need a dedicated method in WorkspaceManagerViewModel
        workspaceManager.reorderPresets(for: workspace, newPresets: presets)

        // Refresh the view
        refreshTrigger = UUID()
    }

    // MARK: - Rename Sheet

    private func renameSheet(preset: WorkspacePreset) -> some View {
        VStack(spacing: 16) {
            Text("Rename Preset")
                .font(fontPreset.headlineFont)
            TextField("New name", text: $renameField)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(minWidth: fontPreset.scaledMetric(200))

            HStack {
                Spacer()
                Button("Cancel") {
                    presetBeingRenamed = nil
                }
                Button("Save") {
                    let finalName = renameField.trimmingCharacters(in: .whitespaces)
                    guard !finalName.isEmpty else { return }
                    workspaceManager.renamePreset(preset, newName: finalName, in: workspace)
                    refreshTrigger = UUID() // Refresh the view
                    presetBeingRenamed = nil
                }
            }
        }
        .padding()
        .frame(width: fontPreset.scaledClamped(360, max: 460))
    }
}
