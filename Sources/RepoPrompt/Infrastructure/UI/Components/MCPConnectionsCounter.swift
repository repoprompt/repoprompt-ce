import SwiftUI

/// A compact, live-updating connections counter button that opens the full status view
struct MCPConnectionsCounter: View {
    @ObservedObject var server: MCPServerViewModel
    let windowID: Int
    var onDismiss: (() -> Void)?

    @State private var isHovering = false

    private var connectionCount: Int {
        server.dashboard?.connections.count ?? 0
    }

    private var hasActivity: Bool {
        server.dashboard?.connections.contains { $0.activeToolName != nil } ?? false
            || server.activeToolName != nil
    }

    private var statusColor: Color {
        if hasActivity {
            .blue
        } else if connectionCount > 0 {
            .green
        } else {
            .secondary
        }
    }

    var body: some View {
        Button {
            HoverTooltipCoordinator.dismissAll()
            NotificationCenter.default.post(
                name: .showMCPStatusWindow,
                object: nil,
                userInfo: ["windowID": windowID]
            )
            onDismiss?()
        } label: {
            HStack(spacing: 5) {
                // Activity indicator or connection icon
                ZStack {
                    if hasActivity {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.4)
                    } else {
                        Image(systemName: "link")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(statusColor)
                    }
                }
                .frame(width: 14, height: 14)

                // Connection count
                Text("\(connectionCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(statusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isHovering ? statusColor.opacity(0.12) : statusColor.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(statusColor.opacity(isHovering ? 0.3 : 0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .hoverTooltip(connectionCount == 0 ? "No connections - View status" : "\(connectionCount) connection\(connectionCount == 1 ? "" : "s")\(hasActivity ? " - Active" : "") - View status")
    }
}
