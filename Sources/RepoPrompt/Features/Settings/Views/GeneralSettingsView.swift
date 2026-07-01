import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String {
        rawValue
    }
}

struct GeneralSettingsView: View {
    // MARK: - Appearance Options

    @AppStorage("instructionsFontSize") private var instructionsFontSize: Double = 13
    @Environment(\.repoPromptFontScalePreset) private var fontPreset
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    // MARK: - Instructions Editor Settings

    @ObservedObject var promptViewModel: PromptViewModel

    // MARK: - View Models

    @ObservedObject var fileManager: WorkspaceFilesViewModel
    @ObservedObject var windowState: WindowState

    /// Computed properties to access managers safely
    private var sparkleManager: SparkleUpdaterManager {
        SparkleUpdaterManager.shared
    }

    private var appearanceMode: AppearanceMode.RawValue {
        globalSettings.appearanceModeRaw()
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

    /// Close action for dismissing the settings view
    var closeAction: (() -> Void)?

    init(
        fileManager: WorkspaceFilesViewModel,
        promptViewModel: PromptViewModel,
        windowState: WindowState,
        closeAction: (() -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.promptViewModel = promptViewModel
        self.windowState = windowState
        self.closeAction = closeAction
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Software Updates Section
                SettingSection(
                    title: "Software Updates",
                    description: "Manage application updates"
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Status row
                        HStack(spacing: 8) {
                            // Status icon and text
                            Image(systemName: sparkleManager.updateAvailable ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                                .foregroundColor(sparkleManager.updateAvailable ? .blue : .green)

                            Text(
                                sparkleManager.updateAvailable ?
                                    "Version \(sparkleManager.updateVersion ?? "Unknown") is available" :
                                    "You have the latest version"
                            )
                            .foregroundColor(sparkleManager.updateAvailable ? .blue : .secondary)

                            Spacer()

                            // Check for updates button
                            Button("Check for Updates") {
                                sparkleManager.checkForUpdates()
                                closeAction?()
                            }
                            .buttonStyle(.bordered)
                        }

                        // Install button (only when update is available)
                        if sparkleManager.updateAvailable {
                            Button("Install Update") {
                                sparkleManager.installUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 2)
                        }

                        // Auto-update toggle (separate row for clarity)
                        Toggle(
                            "Automatically check for updates",
                            isOn: Binding(
                                get: { SparkleUpdaterManager.shared.automaticallyChecksForUpdates },
                                set: { SparkleUpdaterManager.shared.automaticallyChecksForUpdates = $0 }
                            )
                        )
                        .padding(.top, 4)
                    }
                }

                Divider()

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
                    .frame(width: 300, alignment: .leading)
                }

                Divider()

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
                        .frame(width: 300, alignment: .leading)

                        Text("Changes apply immediately.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

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
                    }
                }

                Divider()

                // Instructions Editor Settings
                SettingSection(
                    title: "Instructions Editor Options",
                    description: "Customize behavior and appearance for the instructions text editor."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingToggle(
                            title: "Enable Spell Checking in Instructions",
                            description: "Check for spelling mistakes in the instructions text area",
                            isOn: $promptViewModel.spellCheckInstructions
                        )

                        /*
                         HStack {
                         	Text("Instructions Font Size:")
                         	Slider(value: Binding(
                         		get: { instructionsFontSize },
                         		set: { instructionsFontSize = $0 }
                         	), in: 10...24, step: 1)
                         	Text("\(Int(instructionsFontSize)) pt")
                         		.frame(width: 40, alignment: .trailing)
                         }
                         */
                    }
                }

                Divider()

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Function to copy text to clipboard
private func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

// MARK: - Reusable Settings Components

struct SettingSection<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    var body: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(10, max: 15)) {
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(2, max: 5)) {
                Text(title)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 16, weight: .semibold))
                Text(description)
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                    .foregroundColor(.secondary)
            }
            content
        }
    }
}

struct SettingToggle: View {
    let title: String
    let description: String
    @Binding var isOn: Bool
    var onChange: ((Bool, Bool) -> Void)?
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    var body: some View {
        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(2, max: 5)) {
            Toggle(title, isOn: $isOn)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 13))
                .onChange(of: isOn, onChange ?? { _, _ in })
            Text(description)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundColor(.secondary)
                .padding(.leading, fontPreset.scaledClamped(20, max: 28))
        }
    }
}
