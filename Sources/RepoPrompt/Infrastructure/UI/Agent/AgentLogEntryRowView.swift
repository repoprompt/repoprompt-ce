import SwiftUI

/// Style variants for log entry rows
enum AgentLogRowStyle {
    case compact // Smaller, denser (for discovery view)
    case regular // Standard size (for agent mode)
}

/// A reusable log entry row with consistent icon/color mapping.
struct AgentLogEntryRowView: View {
    let entry: AgentLogEntry
    var style: AgentLogRowStyle = .regular

    @Environment(\.showDatesInMessageTimestamps) private var showDatesInMessageTimestamps

    var body: some View {
        HStack(alignment: .top, spacing: style == .compact ? 6 : 8) {
            Image(systemName: icon)
                .font(style == .compact ? .caption2 : .caption)
                .foregroundColor(color)
                .frame(width: style == .compact ? 12 : 16, alignment: .center)

            Text(formattedMessage)
                .font(style == .compact ? .caption : .callout)
                .foregroundColor(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(timestamp)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.vertical, style == .compact ? 0 : 4)
    }

    private var formattedMessage: String {
        // Remove "Using tool: " prefix if present
        if entry.message.hasPrefix("Using tool: ") {
            return String(entry.message.dropFirst("Using tool: ".count))
        }
        return entry.message
    }

    private var timestamp: String {
        MessageTimestampFormatter.string(
            from: entry.timestamp,
            includeDateContext: showDatesInMessageTimestamps
        )
    }

    private var icon: String {
        switch entry.type {
        case .user: "person.fill"
        case .assistant: "cpu"
        case .tool: "gearshape.fill"
        case .system: "info.circle"
        case .error: "exclamationmark.triangle.fill"
        case .thinking: "brain"
        }
    }

    private var color: Color {
        switch entry.type {
        case .user: .blue
        case .assistant: .primary
        case .tool: .orange
        case .system: .secondary
        case .error: .red
        case .thinking: .purple
        }
    }
}
