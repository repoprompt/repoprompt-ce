//
//  MCPApprovalOverlayView.swift
//  RepoPrompt
//
//  Created by RepoPrompt MCP integration
//

import SwiftUI

/// A full-screen takeover overlay for MCP client approval requests.
/// Presents a modern, polished UI that blocks interaction until the user responds.
struct MCPApprovalOverlayView: View {
    @EnvironmentObject private var server: MCPServerViewModel
    @State private var isAnimating = false
    @State private var isResolving = false
    @State private var pulseScale: CGFloat = 1.0

    let clientID: String
    let generation: UInt64

    var body: some View {
        ZStack {
            // Animated gradient background
            backgroundLayer

            // Content card
            approvalCard
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                isAnimating = true
            }
            // Start pulse animation
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseScale = 1.08
            }
        }
    }

    // MARK: - Background Layer

    private var backgroundLayer: some View {
        ZStack {
            // Dark overlay
            Color.black.opacity(0.5)

            // Subtle radial gradient from center
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.accentColor.opacity(0.15),
                    Color.clear
                ]),
                center: .center,
                startRadius: 100,
                endRadius: 400
            )
        }
        .opacity(isAnimating ? 1 : 0)
    }

    // MARK: - Approval Card

    private var approvalCard: some View {
        VStack(spacing: 0) {
            // Header with icon
            headerSection

            Divider()
                .background(Color.primary.opacity(0.1))

            // Main content
            contentSection

            Divider()
                .background(Color.primary.opacity(0.1))

            // Actions
            actionsSection
        }
        .frame(width: 420)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
        .scaleEffect(isAnimating ? 1 : 0.9)
        .opacity(isAnimating ? 1 : 0)
    }

    private var cardBackground: some View {
        ZStack {
            // Base material
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)

            // Subtle border
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Animated connection icon
            ZStack {
                // Outer pulse ring
                Circle()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .scaleEffect(pulseScale)

                // Inner circle with icon
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor,
                                Color.accentColor.opacity(0.8)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 10)

                Image(systemName: "link.badge.plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)

            Text("Connection Request")
                .font(.title2.weight(.semibold))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content Section

    private var contentSection: some View {
        VStack(spacing: 20) {
            // Client info card
            clientInfoCard

            Text("Client names are self-reported. Approval applies only to this connection; future connections require approval again.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
    }

    private var clientInfoCard: some View {
        HStack(spacing: 16) {
            // Client icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 48, height: 48)

                Image(systemName: clientIcon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(clientID)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("wants to connect to RepoPrompt")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var clientIcon: String {
        let lowercased = clientID.lowercased()
        if lowercased.contains("claude") {
            return "brain"
        } else if lowercased.contains("cursor") {
            return "cursorarrow.rays"
        } else if lowercased.contains("vscode") || lowercased.contains("code") {
            return "chevron.left.forwardslash.chevron.right"
        } else if lowercased.contains("codex") {
            return "terminal"
        } else if lowercased.contains("gemini") {
            return "sparkles"
        } else {
            return "app.connected.to.app.below.fill"
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        HStack(spacing: 12) {
            // Deny button
            Button(action: { Task { await deny() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Deny")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .buttonStyle(MCPDenyButtonStyle())

            // Allow button
            Button(action: { Task { await allow() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Allow Once")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
            .buttonStyle(MCPAllowButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .disabled(isResolving)
    }

    // MARK: - Actions

    private func allow() async {
        guard !isResolving else { return }
        isResolving = true
        withAnimation(.easeInOut(duration: 0.2)) {
            isAnimating = false
        }
        // Small delay for animation
        try? await Task.sleep(nanoseconds: 150_000_000)
        await server.resolveApproval(allow: true, generation: generation)
    }

    private func deny() async {
        guard !isResolving else { return }
        isResolving = true
        withAnimation(.easeInOut(duration: 0.2)) {
            isAnimating = false
        }
        // Small delay for animation
        try? await Task.sleep(nanoseconds: 150_000_000)
        await server.resolveApproval(allow: false, generation: generation)
    }
}

// MARK: - Custom Button Styles

private struct MCPAllowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.green,
                                Color.green.opacity(0.85)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct MCPDenyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
