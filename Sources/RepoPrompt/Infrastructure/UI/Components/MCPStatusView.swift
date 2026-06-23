//
//  MCPStatusView.swift
//  RepoPrompt
//
//  Created by RepoPrompt MCP integration
//

import SwiftUI

/// A comprehensive MCP server status dashboard view.
/// Shows connections, tool activity, and auto-approve management.
struct MCPStatusView: View {
    @ObservedObject var server: MCPServerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header - Fixed at top
            headerSection
                .padding(24)
                .padding(.bottom, 0) // Reduce bottom padding since divider follows

            Divider()
            // .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Server Status
                    serverStatusSection

                    Divider()

                    // Live Activity
                    liveActivitySection

                    Divider()

                    // Connections
                    connectionsSection

                    Divider()

                    // Auto-Approve Management
                    autoApproveSection
                }
                .padding(24)
                .padding(.top, 12) // Reduce top padding since divider is above
            }
        }
        .frame(minWidth: 500, maxWidth: 600)
        .frame(minHeight: 500, maxHeight: 700)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { server.startDashboardUpdates() }
        .onDisappear { server.stopDashboardUpdates() }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("MCP Server Status")
                    .font(.title2.weight(.semibold))

                Text("Monitor connections and manage client approvals")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Server Status Section

    private var serverStatusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Server Status", systemImage: "server.rack")
                .font(.headline)

            VStack(spacing: 0) {
                // Status row
                HStack(spacing: 12) {
                    // Status dot
                    Circle()
                        .fill(server.isRunning ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.isRunning ? "Active" : "Inactive")
                            .font(.subheadline.weight(.medium))

                        Text(server.diagnostics.listenerStateDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Error indicator if present
                    if let issue = server.lastErrorMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(issue)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: 200, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(statusCardBackground)
        }
    }

    private var statusCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    // MARK: - Live Activity Section

    private var liveActivitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Live Tool Activity", systemImage: "bolt.fill")
                .font(.headline)

            let activeConnections = server.dashboard?.connections.filter { $0.activeToolName != nil } ?? []

            if activeConnections.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                    Text("No active tool calls")
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusCardBackground)
            } else {
                VStack(spacing: 8) {
                    ForEach(activeConnections) { conn in
                        activeToolRow(conn)
                    }
                }
            }

            // Recent tool call history
            let recentCalls = server.dashboard?.recentToolCalls ?? []
            if !recentCalls.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)

                    VStack(spacing: 4) {
                        ForEach(recentCalls) { entry in
                            recentToolCallRow(entry)
                        }
                    }
                }
                .padding(12)
                .background(statusCardBackground)
            }
        }
    }

    private func recentToolCallRow(_ entry: MCPService.ToolCallHistoryEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle")
                .foregroundColor(.secondary)
                .font(.caption)

            Text(entry.toolName)
                .font(.caption.monospaced())
                .lineLimit(1)

            Spacer()

            Text(entry.clientName)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(entry.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func activeToolRow(_ conn: MCPService.DashboardConnection) -> some View {
        HStack(spacing: 12) {
            // Animated spinner
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.7)

            VStack(alignment: .leading, spacing: 2) {
                Text(conn.activeToolName ?? "Unknown")
                    .font(.subheadline.weight(.medium))

                Text(conn.clientName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let windowID = conn.windowID {
                Text("Window \(windowID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.1))
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.blue.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Connections Section

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Active Connections", systemImage: "link")
                    .font(.headline)

                Spacer()

                if let count = server.dashboard?.connections.count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                }
            }

            if let connections = server.dashboard?.connections, !connections.isEmpty {
                VStack(spacing: 8) {
                    ForEach(connections) { conn in
                        connectionRow(conn)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "link.badge.plus")
                        .foregroundColor(.secondary)
                    Text("No active connections")
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusCardBackground)
            }
        }
    }

    private func connectionRow(_ conn: MCPService.DashboardConnection) -> some View {
        HStack(spacing: 12) {
            // Connection icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 36, height: 36)

                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conn.clientName)
                        .font(.subheadline.weight(.medium))

                    connectionStateBadge(conn.state)
                }

                HStack(spacing: 12) {
                    if let idle = conn.idleSeconds {
                        Label(formatIdleTime(idle), systemImage: "clock")
                    }

                    Label("\(conn.totalToolCalls) calls", systemImage: "hammer")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if let windowID = conn.windowID {
                Text("W\(windowID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Terminate button
            Button(action: { server.terminateConnection(conn.id, reason: .userBootFromDashboard) }) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTooltip("Terminate this client (CLI will exit)")
        }
        .padding(12)
        .background(statusCardBackground)
    }

    private func connectionStateBadge(_ state: ConnectionStateSummary) -> some View {
        let (color, text): (Color, String) = switch state {
        case .ready: (.green, "Ready")
        case .setup: (.orange, "Setup")
        case .waiting: (.yellow, "Waiting")
        case .failed: (.red, "Failed")
        case .cancelled: (.gray, "Cancelled")
        case .unknown: (.gray, "Unknown")
        }

        return Text(text)
            .font(.caption2.weight(.medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
    }

    private func formatIdleTime(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            "\(Int(seconds))s idle"
        } else if seconds < 3600 {
            "\(Int(seconds / 60))m idle"
        } else {
            "\(Int(seconds / 3600))h idle"
        }
    }

    // MARK: - Auto-Approve Section

    private var autoApproveSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Auto-Approve Settings", systemImage: "checkmark.shield")
                    .font(.headline)

                Spacer()

                // Global toggle
                Toggle("", isOn: Binding(
                    get: { server.dashboard?.autoApproveAllClients ?? false },
                    set: { server.setAutoApproveAllClients($0) }
                ))
                .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                .labelsHidden()
            }

            Text("When enabled, all new clients connect without approval prompts")
                .font(.caption)
                .foregroundColor(.secondary)

            // Always-allowed clients list
            let allowedClients = server.dashboard?.alwaysAllowedClients ?? []

            VStack(alignment: .leading, spacing: 12) {
                Text("Trusted Clients")
                    .font(.subheadline.weight(.medium))

                if allowedClients.isEmpty {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .foregroundColor(.secondary)
                        Text("No clients in the persistent allow-list")
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(statusCardBackground)
                } else {
                    VStack(spacing: 6) {
                        ForEach(allowedClients, id: \.self) { client in
                            allowedClientRow(client)
                        }
                    }
                }
            }
        }
    }

    private func allowedClientRow(_ client: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)

            Text(client)
                .font(.subheadline)

            Spacer()

            if server.isBuiltInAlwaysAllowedClient(client) {
                Text("Built-in")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .hoverTooltip("Built-in clients are always trusted and can't be removed")
                    .accessibilityHint("Always trusted and cannot be removed")
            } else {
                Button(action: { server.setAlwaysAllowed(clientID: client, allowed: false) }) {
                    Text("Remove")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// MARK: - MCP Status Window Coordinator

/// Notification name for showing the MCP status window
extension Notification.Name {
    static let showMCPStatusWindow = Notification.Name("showMCPStatusWindow")
}
