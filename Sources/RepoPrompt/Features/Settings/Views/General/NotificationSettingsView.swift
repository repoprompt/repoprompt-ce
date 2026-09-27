import AppKit
import SwiftUI

/// Settings → General → Notifications. Every toggle is driven by `NotificationSettingDescriptor`, the
/// same table that backs the `app_settings` `notifications` group.
struct NotificationSettingsView: View {
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    @Environment(\.repoPromptFontScalePreset) private var fontPreset
    @State private var authorizationStatus: NotificationAuthorizationStatus = .notDetermined

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: fontPreset.scaledClamped(18, max: 26)) {
                SettingSection(
                    title: "Notifications",
                    description: "Get notified when agent sessions need you, answer simple requests from the notification, and jump straight to the exact session by clicking it."
                ) {
                    VStack(alignment: .leading, spacing: fontPreset.scaledClamped(10, max: 14)) {
                        authorizationRow
                        toggles(in: .general)
                    }
                }

                ForEach(
                    [NotificationSettingDescriptor.Section.agentSessions, .responding, .chat],
                    id: \.self
                ) { section in
                    SettingSection(title: section.rawValue, description: sectionDescription(section)) {
                        VStack(alignment: .leading, spacing: fontPreset.scaledClamped(10, max: 14)) {
                            toggles(in: section)
                        }
                    }
                    .disabled(!globalSettings.notificationPreferences().enabled)
                }
            }
            .padding(fontPreset.scaledClamped(20, max: 28))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            authorizationStatus = await NotificationService.shared.refreshAuthorizationStatus()
        }
    }

    private func toggles(in section: NotificationSettingDescriptor.Section) -> some View {
        ForEach(NotificationSettingDescriptor.all.filter { $0.section == section }, id: \.key) { descriptor in
            SettingToggle(
                title: descriptor.label,
                description: descriptor.description,
                isOn: Binding(
                    get: { globalSettings.notificationSetting(descriptor) },
                    set: { globalSettings.setNotificationSetting(descriptor, $0) }
                )
            )
        }
    }

    private func sectionDescription(_ section: NotificationSettingDescriptor.Section) -> String {
        switch section {
        case .general:
            ""
        case .agentSessions:
            "Which Agent Mode events notify you. Notifications are grouped per session and removed once the request is handled anywhere."
        case .responding:
            "Actions are validated against the live request when you press them; anything stale, risky, or complex opens RepoPrompt instead."
        case .chat:
            "Completion notifications for Chat and Context Builder."
        }
    }

    private var authorizationRow: some View {
        HStack(spacing: 8) {
            Image(systemName: authorizationStatus.allowsDelivery ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(authorizationStatus.allowsDelivery ? .green : .orange)
            Text(authorizationText)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Button("Open System Settings…") {
                openSystemNotificationSettings()
            }
        }
    }

    private var authorizationText: String {
        switch authorizationStatus {
        case .authorized, .provisional:
            "macOS notifications are allowed for RepoPrompt."
        case .denied:
            "macOS notifications are turned off for RepoPrompt. RepoPrompt falls back to bouncing the Dock icon."
        case .notDetermined:
            "RepoPrompt has not been granted notification permission yet."
        case .unavailable:
            "Notifications are unavailable in this build context."
        }
    }

    private func openSystemNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ].compactMap(URL.init(string:))
        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }
}
