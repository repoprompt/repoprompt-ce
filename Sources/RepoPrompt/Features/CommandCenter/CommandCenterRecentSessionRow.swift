import SwiftUI

/// Restored from the original CC build. Native List selection supplies its original row
/// background, fonts and chrome. Only the surrounding tabs/search use current main components.
struct CommandCenterRecentSessionRow: View {
    let row: CommandCenterSessionRow
    let project: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.name).lineLimit(1)
            Text("\(project) · \(row.workspaceID.uuidString.prefix(8))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Text(status)
                Spacer()
                if row.activityDate != .distantPast { Text(row.activityDate, style: .relative) }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
            .hoverTooltip(row.detail ?? (row.attention == .saved ? "Saved metadata — not a live run-state observation" : project))
    }

    private var status: String {
        switch row.attention {
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .finished: "Finished"
        case .working: "Working"
        case .idle: "Idle"
        case .saved: "Saved"
        case .unknown: "Unknown / unavailable"
        }
    }
}
