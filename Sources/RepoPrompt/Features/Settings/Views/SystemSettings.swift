//
//  SystemSettings.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-16.
//

import SwiftUI

struct SystemSettingsView: View {
    // MARK: - Appearance Options

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    private var appearanceModeBinding: Binding<AppearanceMode.RawValue> {
        Binding(
            get: { globalSettings.appearanceModeRaw() },
            set: { newValue in
                globalSettings.setAppearanceModeRaw(newValue)
                AppearanceController.shared.apply(modeRawValue: newValue)
            }
        )
    }

    private var useTransparencyBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.useTransparency() },
            set: { globalSettings.setUseTransparency($0) }
        )
    }

    // MARK: - View Models

    @ObservedObject var sparkleManager: SparkleUpdaterManager
    var closeAction: (() -> Void)?

    init(
        sparkleManager: SparkleUpdaterManager,
        closeAction: (() -> Void)? = nil
    ) {
        self.sparkleManager = sparkleManager
        self.closeAction = closeAction
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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

                            Text(sparkleManager.availableUpdate?.availabilityStatus ?? "You have the latest version")
                                .foregroundColor(sparkleManager.updateAvailable ? .blue : .secondary)

                            Spacer()

                            // Check for updates button
                            Button("Check for Updates") {
                                sparkleManager.checkForUpdates()
                                closeAction?()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!sparkleManager.canCheckForUpdates)
                        }

                        if let message = sparkleManager.updatesDisabledMessage {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        // Install button (only when update is available)
                        if let availableUpdate = sparkleManager.availableUpdate {
                            Button(availableUpdate.installButtonTitle) {
                                sparkleManager.installUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 2)
                        }

                        // Auto-update toggle (separate row for clarity)
                        Toggle(
                            "Automatically check for updates",
                            isOn: $sparkleManager.automaticallyChecksForUpdates
                        )
                        .padding(.top, 4)
                    }
                }

                Divider()

                // Appearance Section
                SettingSection(
                    title: "Appearance",
                    description: "Customize the app's appearance"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Dark mode selector
                        Picker("Theme", selection: appearanceModeBinding) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 300)
                        .padding(.bottom, 8)

                        // Transparency toggle
                        SettingToggle(
                            title: "Use transparency effects",
                            description: "Enable window transparency and blur effects. Requires app restart to take effect.",
                            isOn: useTransparencyBinding
                        )
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
