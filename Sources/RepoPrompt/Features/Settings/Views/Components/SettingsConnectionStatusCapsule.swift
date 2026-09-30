import SwiftUI

enum SettingsConnectionStatus: Equatable {
    case connected
    case notConnected
    case connecting
    case unavailable
    case error

    var label: String {
        switch self {
        case .connected: "Connected"
        case .notConnected: "Not Connected"
        case .connecting: "Connecting"
        case .unavailable: "Unavailable"
        case .error: "Error"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .connected: .green
        case .notConnected: .secondary
        case .connecting: .orange
        case .unavailable, .error: .red
        }
    }
}

/// Shared provider-card status treatment. The Boolean initializer preserves the CLI card API.
struct SettingsConnectionStatusCapsule: View {
    let status: SettingsConnectionStatus
    var connectedLabel: String = "Connected"
    var disconnectedLabel: String = "Not Connected"
    var labelOverride: String?

    init(
        status: SettingsConnectionStatus,
        connectedLabel: String = "Connected",
        disconnectedLabel: String = "Not Connected",
        labelOverride: String? = nil
    ) {
        self.status = status
        self.connectedLabel = connectedLabel
        self.disconnectedLabel = disconnectedLabel
        self.labelOverride = labelOverride
    }

    init(
        isConnected: Bool,
        connectedLabel: String = "Connected",
        disconnectedLabel: String = "Not Connected",
        labelOverride: String? = nil
    ) {
        self.init(
            status: isConnected ? .connected : .notConnected,
            connectedLabel: connectedLabel,
            disconnectedLabel: disconnectedLabel,
            labelOverride: labelOverride
        )
    }

    private var displayedLabel: String {
        if let labelOverride { return labelOverride }
        return switch status {
        case .connected: connectedLabel
        case .notConnected: disconnectedLabel
        case .connecting, .unavailable, .error: status.label
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(displayedLabel)
                .font(.caption)
                .foregroundColor(status.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(status.color.opacity(status == .connected ? 0.1 : 0.08))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayedLabel)
    }
}
