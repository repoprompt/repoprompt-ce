//
//  AppearanceSettingsView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-16.
//

import SwiftUI

struct AppearanceSettingsView: View {
    // Appearance preferences are persisted in the JSON-backed GlobalSettingsStore.
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    /// Prompt view model for spell checking
    @ObservedObject var promptViewModel: PromptViewModel

    init(promptViewModel: PromptViewModel) {
        self.promptViewModel = promptViewModel
    }

    private var appearanceModeBinding: Binding<AppearanceMode.RawValue> {
        Binding(
            get: { globalSettings.appearanceModeRaw() },
            set: { newValue in
                globalSettings.setAppearanceModeRaw(newValue)
                AppearanceController.shared.apply(modeRawValue: newValue)
            }
        )
    }

    private var collapseLatestFileChangesBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.collapseLatestFileChanges() },
            set: { globalSettings.setCollapseLatestFileChanges($0) }
        )
    }

    private var showTooltipsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.showTooltips() },
            set: { globalSettings.setShowTooltips($0) }
        )
    }

    private var showDatesInMessageTimestampsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.showDatesInMessageTimestamps() },
            set: { globalSettings.setShowDatesInMessageTimestamps($0) }
        )
    }

    private var experimentalAttributedTextEditorBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.experimentalAttributedTextEditor() },
            set: { globalSettings.setExperimentalAttributedTextEditor($0) }
        )
    }

    private var fileMentionPickerStyleBinding: Binding<FileMentionPickerStyle> {
        Binding(
            get: { globalSettings.fileMentionPickerStyle() },
            set: { globalSettings.setFileMentionPickerStyle($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Theme Section
                SettingSection(
                    title: "Theme",
                    description: "Choose your preferred color scheme"
                ) {
                    Picker("", selection: appearanceModeBinding) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .labelsHidden()
                    .frame(width: fontPreset.scaledClamped(300, max: 390), alignment: .leading)
                }
                .padding(.horizontal, fontPreset.scaledClamped(16, max: 24))
                .padding(.top, fontPreset.scaledClamped(16, max: 24))

                Divider()
                    .padding(.vertical, fontPreset.scaledClamped(16, max: 24))

                // Text Size Section
                SettingSection(
                    title: "Text Size",
                    description: "Controls the app's global text size"
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: Binding(
                            get: { fontPreset.rawValue },
                            set: { FontScaleManager.shared.setRawValue($0) }
                        )) {
                            ForEach(FontScalePreset.allCases) { preset in
                                Text(preset.displayName).tag(preset.rawValue)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .labelsHidden()
                        .frame(width: fontPreset.scaledClamped(300, max: 390), alignment: .leading)

                        Text("Changes apply immediately.")
                            .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, fontPreset.scaledClamped(16, max: 24))

                Divider()
                    .padding(.vertical, fontPreset.scaledClamped(16, max: 24))

                // Display Options Section
                SettingSection(
                    title: "Display Options",
                    description: "Configure visual behavior"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingToggle(
                            title: "Always Collapse File Changes",
                            description: "Reduces performance strain on very large generations.",
                            isOn: collapseLatestFileChangesBinding
                        )

                        SettingToggle(
                            title: "Show Tooltips",
                            description: "Enable tooltips when hovering over elements.",
                            isOn: showTooltipsBinding
                        )

                        SettingToggle(
                            title: "Show dates in message timestamps",
                            description: "Add Yesterday, weekday, or date labels to message and tool timestamps.",
                            isOn: showDatesInMessageTimestampsBinding
                        )
                    }
                }
                .padding(.horizontal, fontPreset.scaledClamped(16, max: 24))

                Divider()
                    .padding(.vertical, fontPreset.scaledClamped(16, max: 24))

                // Text Editing Options
                SettingSection(
                    title: "Text Editing",
                    description: "Configure text editing behavior"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingToggle(
                            title: "Enable Spell Checking in Instructions",
                            description: "Check for spelling mistakes in the instructions text area",
                            isOn: $promptViewModel.spellCheckInstructions
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("@ File Picker Style")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 13))

                            Picker("@ File Picker Style", selection: fileMentionPickerStyleBinding) {
                                ForEach(FileMentionPickerStyle.allCases) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: fontPreset.scaledClamped(240, max: 320), alignment: .leading)

                            Text("Choose Compact or Expanded density for file @ mention suggestions.")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                                .foregroundColor(.secondary)
                        }

                        // Experimental toggle for the @-mention menu
                        SettingToggle(
                            title: "Enable @-Mention Menu (Experimental)",
                            description: "Allows you to tag files directly in the compose prompt box using \"@file\" suggestions.",
                            isOn: experimentalAttributedTextEditorBinding
                        )
                    }
                }
                .padding(.horizontal, fontPreset.scaledClamped(16, max: 24))
                .padding(.bottom, fontPreset.scaledClamped(16, max: 24))

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
    }
}
