import SwiftUI

enum SettingsProviderConnectionActionRole {
    case primary
    case secondary
}

/// Shared provider-card action treatment used by CLI providers and Figma.
struct SettingsProviderConnectionActionButton: View {
    let title: String
    let systemImage: String
    let isLoading: Bool
    let isDisabled: Bool
    let role: SettingsProviderConnectionActionRole
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    init(
        title: String,
        systemImage: String,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        role: SettingsProviderConnectionActionRole = .primary,
        accessibilityLabel: String? = nil,
        accessibilityHint: String = "",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.role = role
        self.accessibilityLabel = accessibilityLabel ?? title
        self.accessibilityHint = accessibilityHint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(height: 16)
                    .accessibilityHidden(true)
            } else {
                Label(title, systemImage: systemImage)
                    .foregroundColor(role == .secondary ? .secondary : .primary)
            }
        }
        .disabled(isDisabled)
        .buttonStyle(CustomButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}
