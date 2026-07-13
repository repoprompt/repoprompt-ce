import SwiftUI

struct TelemetrySettingsView: View {
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @Environment(\.repoPromptFontScalePreset) private var fontPreset

    private var telemetryEnabledBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.telemetryEnabled() },
            set: { globalSettings.setTelemetryEnabled($0) }
        )
    }

    private var appHangReportsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.telemetryAppHangReportsEnabled() },
            set: { globalSettings.setTelemetryAppHangReportsEnabled($0) }
        )
    }

    private var performanceTracingBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.telemetryPerformanceTracingEnabled() },
            set: { globalSettings.setTelemetryPerformanceTracingEnabled($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(18, max: 26)) {
                SettingSection(
                    title: "Telemetry",
                    description: "Privacy-respecting crash and diagnostic reporting for official builds."
                ) {
                    VStack(alignment: .leading, spacing: fontPreset.scaledClamped(10, max: 14)) {
                        statusBanner

                        SettingToggle(
                            title: "Share crash reports and diagnostics",
                            description: "Allows Sentry crash reporting, app hang reports, and optional startup performance traces when this build is configured with telemetry. Automatic release-health sessions are disabled to avoid stable installation identifiers.",
                            isOn: telemetryEnabledBinding
                        )
                        .disabled(!SentryTelemetryBootstrap.currentStatus().sdkCompiledIn)

                        SettingToggle(
                            title: "App hang reports",
                            description: "Reports when the app appears stuck for long enough to be detected by the crash-reporting SDK. Requires telemetry to be enabled.",
                            isOn: appHangReportsBinding
                        )
                        .disabled(!globalSettings.telemetryEnabled())

                        SettingToggle(
                            title: "Performance timing and tracing",
                            description: "Sends a conservative sample of startup timing traces. Manual tool and agent-run metrics are not sent in this build.",
                            isOn: performanceTracingBinding
                        )
                        .disabled(!globalSettings.telemetryEnabled())
                    }
                }

                SettingSection(
                    title: "Privacy",
                    description: "What RepoPrompt sends and what it never sends."
                ) {
                    VStack(alignment: .leading, spacing: fontPreset.scaledClamped(8, max: 12)) {
                        bullet("Collected: crash diagnostics, app hangs when enabled, release/build metadata, OS/app version, and optional startup performance timing.")
                        bullet("Never intentionally sent: prompt contents, chat transcripts, selected file contents, tool payloads, API keys, provider tokens, or full local paths.")
                        bullet("Automatic failed-request capture and automatic release-health session tracking are disabled.")
                        bullet("A defense-in-depth scrubber removes request payloads, headers, cookies, query strings, obvious secrets, local home paths, user/geo/server identifiers, stable device identifiers, and IP-like values from events before upload.")
                        bullet("Set REPOPROMPT_TELEMETRY_DISABLED=1 before launch to disable telemetry for the process regardless of Settings.")
                    }
                }
            }
            .padding(fontPreset.scaledClamped(20, max: 28))
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        let status = SentryTelemetryBootstrap.currentStatus()
        let message = if !status.sdkCompiledIn {
            "Telemetry is inactive in this build because the Sentry SDK is not linked."
        } else if status.environmentDisabled {
            "Telemetry is disabled by REPOPROMPT_TELEMETRY_DISABLED for this process."
        } else if !status.dsnConfigured {
            "Telemetry is inactive in this build because no Sentry DSN is configured."
        } else if !status.telemetryEnabled {
            "Telemetry is disabled in Settings."
        } else if status.started {
            "Telemetry is active for this build."
        } else {
            "Telemetry is enabled and will start when the app initializes telemetry."
        }

        Text(message)
            .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
            .foregroundColor(.secondary)
            .padding(fontPreset.scaledClamped(10, max: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: fontPreset.scaledClamped(6, max: 9)) {
            Text("•")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .foregroundColor(.secondary)
            Text(text)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 12))
                .foregroundColor(.secondary)
        }
    }
}
