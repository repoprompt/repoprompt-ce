//
//  AgentOnboardingWizardView.swift
//  RepoPrompt
//
//  Created by RepoPrompt on 2026-02-05.
//

import SwiftUI

// MARK: - Agent Onboarding Wizard View

enum AgentOnboardingWizardExitPolicy {
    static func perform(
        markOnboardingSeen: () -> Void,
        onContinueToMain: (() -> Void)?,
        onDismiss: (() -> Void)?
    ) {
        markOnboardingSeen()
        if let onContinueToMain {
            onContinueToMain()
        } else {
            onDismiss?()
        }
    }
}

struct AgentOnboardingWizardView: View {
    @ObservedObject var viewModel: AgentOnboardingWizardViewModel
    var windowID: Int?
    var onDismiss: (() -> Void)?
    var onContinueToMain: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            progressBar

            wizardHeader
                .padding(.horizontal, 60)
                .padding(.top, 32)

            Divider()
                .padding(.top, 12)

            stepContent
                .padding(.horizontal, 60)
                .padding(.vertical, 24)

            Spacer(minLength: 0)

            Divider()

            wizardFooter
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * viewModel.progressFraction)
                    .animation(.easeInOut(duration: 0.4), value: viewModel.progressFraction)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Header

    private var wizardHeader: some View {
        HStack(alignment: .top) {
            if let step = viewModel.currentStep {
                Image(systemName: step.systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .id(step.systemImage)
                    .transition(.scale.combined(with: .opacity))

                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(.largeTitle.bold())
                        .id("title-\(step.rawValue)")
                        .transition(.push(from: .trailing))

                    Text(step.subtitle)
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .id("subtitle-\(step.rawValue)")
                        .transition(.push(from: .trailing))
                }
            }

            Spacer()

            Text(viewModel.progressText)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.currentStepIndex)
    }

    // MARK: - Step Content

    private var stepContent: some View {
        ScrollView {
            Group {
                switch viewModel.currentStep {
                case .welcome:
                    WelcomeStepView(viewModel: viewModel, windowID: windowID)
                case .agentModeIntro:
                    AgentModeIntroStepView()
                case .contextBuilder:
                    ContextBuilderStepView()
                case .mcpSetup:
                    MCPSetupStepView(viewModel: viewModel, windowID: windowID)
                case .providers:
                    ProvidersStepView(viewModel: viewModel, windowID: windowID)
                case .completion:
                    CompletionStepView(
                        viewModel: viewModel,
                        windowID: windowID,
                        canContinueToMain: onContinueToMain != nil,
                        onExit: exitWizard
                    )
                case .none:
                    EmptyView()
                }
            }
            .id(viewModel.currentStepIndex)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.35), value: viewModel.currentStepIndex)
        }
    }

    // MARK: - Footer

    private var wizardFooter: some View {
        HStack {
            if viewModel.canGoBack {
                Button(action: { withAnimation { viewModel.previousStep() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Spacer()

            if viewModel.currentStep == .completion {
                Button(action: { exitWizard() }) {
                    HStack(spacing: 8) {
                        Text("Get Started")
                        Image(systemName: "arrow.right")
                    }
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Skip All") {
                    skipAll()
                }
                .font(.body)
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button(action: { withAnimation { viewModel.nextStep() } }) {
                    HStack(spacing: 8) {
                        Text(nextButtonLabel)
                        Image(systemName: "chevron.right")
                    }
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var nextButtonLabel: String {
        switch viewModel.currentStep {
        case .welcome: "Let's Go"
        case .agentModeIntro: "Next"
        case .contextBuilder: "Next"
        case .mcpSetup: "Finish Setup"
        case .providers: "Next"
        case .completion: "Get Started"
        case .none: "Next"
        }
    }

    private func exitWizard() {
        AgentOnboardingWizardExitPolicy.perform(
            markOnboardingSeen: { viewModel.markOnboardingSeen() },
            onContinueToMain: onContinueToMain,
            onDismiss: onDismiss
        )
    }

    /// "Skip All" mid-wizard continues into the main app when available, otherwise dismisses.
    private func skipAll() {
        exitWizard()
    }
}

// MARK: - Step: Welcome

/// Shared welcome step for RepoPrompt CE.
private struct WelcomeStepView: View {
    @ObservedObject var viewModel: AgentOnboardingWizardViewModel
    var windowID: Int?
    @State private var showCards = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Welcome! RepoPrompt CE includes Agent Mode, Context Builder workflows, token-efficient MCP tools, and full context features.")
                .font(.title3)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 20) {
                ModeCard(
                    icon: "doc.text.magnifyingglass",
                    title: "Context Builder",
                    description: "Generate focused file selections, codemaps, and implementation prompts so reasoning models get the right codebase context.",
                    accentColor: .blue,
                    badge: nil,
                    delay: 0.1
                )

                ModeCard(
                    icon: "terminal",
                    title: "Agent Mode",
                    description: "Orchestrate your CLI agents with full codebase context. Guide them as they work, review changes, and iterate.",
                    accentColor: .purple,
                    badge: nil,
                    delay: 0.25
                )
            }

            // MCP Server card — prominent like the mode cards
            MCPServerCard()
        }
    }
}

private struct MCPServerCard: View {
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundColor(.green)
                Text("Built-in MCP Server")
                    .font(.title3.bold())
            }

            HStack(alignment: .top, spacing: 20) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundColor(.green.opacity(0.8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use in Any Coding Agent")
                            .font(.headline)
                        Text("Give Claude Code, Cursor, Codex, and other MCP-compatible tools access to RepoPrompt's token-efficient context tools.")
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "apple.terminal")
                        .foregroundColor(.green.opacity(0.8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automate with the CLI")
                            .font(.headline)
                        Text("Run context building, file search, and code analysis from your terminal. Script complex workflows or integrate into your own toolchain.")
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.green.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.green.opacity(0.15), lineWidth: 1)
        )
        .scaleEffect(appeared ? 1.0 : 0.92)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.4)) {
                appeared = true
            }
        }
    }
}

private struct ModeCard: View {
    let icon: String
    let title: String
    let description: String
    let accentColor: Color
    let badge: String?
    let delay: Double

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(accentColor)

                Text(title)
                    .font(.title3.bold())

                if let badge {
                    Text(badge)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                }
            }

            Text(description)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accentColor.opacity(0.15), lineWidth: 1)
        )
        .scaleEffect(appeared ? 1.0 : 0.92)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay)) {
                appeared = true
            }
        }
    }
}

// MARK: - Step: Free Features (Free users only)

/// Describes powerful features available in CE.
private struct FreeFeaturesStepView: View {
    @State private var showItems = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("RepoPrompt CE gives you powerful context management for AI coding. Here's what you can do right now:")
                .font(.title3)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    FreeFeatureCard(icon: "doc.on.doc", title: "Smart File Selection", description: "Multi-root workspaces, regex filtering, and full/slice/codemap modes.")
                    FreeFeatureCard(icon: "bubble.left.and.bubble.right", title: "AI Chat", description: "Chat with AI models using your own API keys with full file context.")
                }
                HStack(spacing: 12) {
                    FreeFeatureCard(icon: "doc.badge.arrow.up", title: "Prompt Compose & Copy", description: "Build structured prompts with file trees, git diffs, and instructions.")
                    FreeFeatureCard(icon: "arrow.triangle.2.circlepath", title: "Apply Mode", description: "Paste AI responses to review and apply changes with diff visualization.")
                }
                HStack(spacing: 12) {
                    FreeFeatureCard(icon: "folder.badge.gearshape", title: "Workspaces", description: "Organize projects with multi-root workspaces and persistent settings.")
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .opacity(showItems ? 1 : 0)
            .offset(y: showItems ? 0 : 15)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                showItems = true
            }
        }
    }
}

private struct FreeFeatureCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - Step: Feature Showcase

/// Highlights CE Agent Mode features.
private struct FeatureShowcaseStepView: View {
    @ObservedObject var viewModel: AgentOnboardingWizardViewModel
    let windowID: Int?
    @State private var showItems = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("RepoPrompt CE can be the backend for your AI coding agents. Here's what is available:")
                .font(.title3)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Feature grid
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    FeatureShowcaseRow(
                        icon: "terminal.fill",
                        title: "Agent Mode",
                        description: "CLI agents use RepoPrompt as their session host and context backbone.",
                        color: .purple
                    )
                    FeatureShowcaseRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Context Builder",
                        description: "Two-stage AI pipeline: Context Builder agent curates files, analysis model produces plans and reviews.",
                        color: .blue
                    )
                }
                HStack(spacing: 12) {
                    FeatureShowcaseRow(
                        icon: "server.rack",
                        title: "MCP Server",
                        description: "Token-efficient tools for any MCP client. ~80% fewer tokens than built-in CLI tools.",
                        color: .green
                    )
                    FeatureShowcaseRow(
                        icon: "cube.transparent",
                        title: "CodeMaps",
                        description: "Tree-sitter API signatures. Maximum context, minimum tokens.",
                        color: .orange
                    )
                }
            }
            .opacity(showItems ? 1 : 0)
            .offset(y: showItems ? 0 : 15)

            Text("All CE features are available by default. Connect providers and start using the workflows that fit your project.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.1)) {
                showItems = true
            }
        }
    }
}

private struct FeatureShowcaseRow: View {
    let icon: String
    let title: String
    let description: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.02))
        )
    }
}

// MARK: - Step: Agent Mode Intro

private struct AgentModeIntroStepView: View {
    @State private var showRows = [false, false, false, false]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Agent Mode gives you a beautifully native session host for CLI coding agents — with per-tab sessions, live tool call streaming, and deep integration with RepoPrompt's context engine.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // CLI integrations — compact horizontal row
            HStack(spacing: 12) {
                AgentIntegrationBadge(name: "Codex CLI", icon: "star.fill", status: "Native", color: .purple)
                AgentIntegrationBadge(name: "Claude Code", icon: "terminal", status: "MCP", color: .blue)
                AgentIntegrationBadge(name: "OpenCode", icon: "terminal", status: "MCP", color: .orange)
                AgentIntegrationBadge(name: "Cursor", icon: "cursorarrow", status: "MCP", color: .cyan)
            }

            // Key workflows
            VStack(spacing: 10) {
                AnimatedFeatureRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Context Builder Workflows",
                    description: "Agents trigger Context Builder directly — a Context Builder agent curates the right files, then an analysis model generates plans, reviews, or deep answers.",
                    delay: 0.1,
                    appeared: $showRows[0]
                )

                AnimatedFeatureRow(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "Oracle Chat",
                    description: "Agents can ask RepoPrompt questions about your codebase mid-session. Context Builder finds the answer using your full repo — no manual file selection needed.",
                    delay: 0.25,
                    appeared: $showRows[1]
                )

                AnimatedFeatureRow(
                    icon: "rectangle.stack",
                    title: "Per-Tab Sessions",
                    description: "Each compose tab gets its own agent session. Run multiple agents in parallel across different tasks with isolated context.",
                    delay: 0.4,
                    appeared: $showRows[2]
                )

                AnimatedFeatureRow(
                    icon: "bolt.fill",
                    title: "Token-Efficient Tools",
                    description: "Agents use RepoPrompt's MCP tools for file search, code structure, and editing — ~80% fewer tokens than built-in CLI equivalents.",
                    delay: 0.55,
                    appeared: $showRows[3]
                )
            }
        }
        .onAppear {
            for i in showRows.indices {
                withAnimation(.easeOut(duration: 0.4).delay(Double(i) * 0.15 + 0.1)) {
                    showRows[i] = true
                }
            }
        }
    }
}

/// Compact badge showing a CLI integration and its connection type.
private struct AgentIntegrationBadge: View {
    let name: String
    let icon: String
    let status: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.bold())
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - Step: Context Builder

private struct ContextBuilderStepView: View {
    @State private var showStage1 = false
    @State private var showArrow = false
    @State private var showStage2 = false
    @State private var showWorkflows = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("The Context Builder is a two-stage intelligence pipeline that gives your agents the right context, every time.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                PipelineStageCard(
                    stage: "Stage 1",
                    title: "Context Builder Agent",
                    description: "A specialized research model explores your entire codebase, identifies relevant files, and curates a token-budgeted selection.",
                    icon: "magnifyingglass",
                    color: .blue
                )
                .opacity(showStage1 ? 1 : 0)
                .offset(y: showStage1 ? 0 : 20)

                Image(systemName: "arrow.down")
                    .font(.title3)
                    .foregroundColor(.accentColor.opacity(0.6))
                    .padding(.vertical, 6)
                    .opacity(showArrow ? 1 : 0)
                    .scaleEffect(showArrow ? 1 : 0.5)

                PipelineStageCard(
                    stage: "Stage 2",
                    title: "Analysis Model",
                    description: "A powerful model receives the curated context and produces deep analysis — architectural plans, code reviews, or answers to questions.",
                    icon: "brain",
                    color: .purple
                )
                .opacity(showStage2 ? 1 : 0)
                .offset(y: showStage2 ? 0 : 20)
            }

            // Workflow cards
            VStack(alignment: .leading, spacing: 10) {
                Text("Built-in Workflows")
                    .font(.headline)

                HStack(spacing: 12) {
                    WorkflowCard(
                        command: "/rp-build",
                        title: "Build Features",
                        description: "Context builder gathers files, analysis model creates plan, then you implement directly",
                        color: .blue
                    )
                    WorkflowCard(
                        command: "/rp-review",
                        title: "Code Reviews",
                        description: "Publishes git diffs alongside codebase context for reviews that understand what changed",
                        color: .green
                    )
                    WorkflowCard(
                        command: "/rp-refactor",
                        title: "Refactor Code",
                        description: "Two-pass: analyze for opportunities, then plan implementation preserving behavior",
                        color: .orange
                    )
                    WorkflowCard(
                        command: "/rp-investigate",
                        title: "Investigate Issues",
                        description: "Systematic exploration with evidence gathering until root cause is found",
                        color: .red
                    )
                }
            }
            .opacity(showWorkflows ? 1 : 0)
            .offset(y: showWorkflows ? 0 : 15)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) { showStage1 = true }
            withAnimation(.easeOut(duration: 0.3).delay(0.4)) { showArrow = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.6)) { showStage2 = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.9)) { showWorkflows = true }
        }
    }
}

private struct WorkflowCard: View {
    let command: String
    let title: String
    let description: String
    let color: Color

    var body: some View {
        VStack(spacing: 10) {
            Text(command)
                .font(.subheadline.bold().monospaced())
                .foregroundColor(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color.opacity(0.12))
                )

            Text(title)
                .font(.headline)

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Step: MCP Setup

/// MCP server sales pitch with compact install actions via dropdown menus.
private struct MCPSetupStepView: View {
    @ObservedObject var viewModel: AgentOnboardingWizardViewModel
    let windowID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Optional callout — make it crystal clear that nothing on this step is required
            // for users who plan to work inside Agent Mode.
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("This step is optional")
                            .font(.headline)
                        Text("Skip if you only use Agent Mode")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green))
                    }
                    Text("Agent Mode inside RepoPrompt already includes every tool below — no MCP setup required. Configure the MCP server only if you want to give external clients (Claude Code, Cursor, Codex CLI, OpenCode, Claude Desktop, VS Code) access to RepoPrompt's context tools.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.green.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.green.opacity(0.18), lineWidth: 1)
            )

            Text("If you do want to use RepoPrompt outside the app, the built-in MCP server gives any MCP-compatible client access to the same token-efficient context tools your agents use here.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Quick Install bar at top
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Install")
                    .font(.headline)

                HStack(spacing: 10) {
                    Menu {
                        Button("Cursor") { viewModel.installMCPServer(in: "Cursor") }
                        Button("VS Code") { viewModel.installMCPServer(in: "VS Code") }
                        Button("Codex CLI") { viewModel.installMCPServer(in: "Codex CLI") }
                        Button("OpenCode") { viewModel.installMCPServer(in: "OpenCode") }
                        Button("Claude Desktop") { viewModel.installMCPServer(in: "Claude Desktop") }
                        Button("Claude Code") { viewModel.installMCPServer(in: "Claude Code") }
                    } label: {
                        Label("Install MCP...", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(CustomButtonStyle())

                    Menu {
                        Section {
                            Text("Shared (.agents/skills)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Works with Codex and other agents")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            Menu("Global (~/.agents/skills)") {
                                Button("MCP skills") {
                                    let count = MCPIntegrationHelper.installAgentsSkills(useCLIVariant: false)
                                    viewModel.showInstallFeedbackPublic(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                                }
                                Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                    let count = MCPIntegrationHelper.installAgentsSkills(useCLIVariant: true)
                                    viewModel.showInstallFeedbackPublic(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                                }
                                Divider()
                                Button("Uninstall") {
                                    let count = MCPIntegrationHelper.uninstallAgentsSkills(useCLIVariant: false)
                                    let cliCount = MCPIntegrationHelper.uninstallAgentsSkills(useCLIVariant: true)
                                    viewModel.showInstallFeedbackPublic(count + cliCount > 0 ? "Skills removed" : "Nothing to remove")
                                }
                            }
                        }

                        Section {
                            Text("Claude Code (.claude/commands)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Menu("Per-project") {
                                Button("MCP skills") {
                                    let count = MCPIntegrationHelper.installWorkspaceSkills(workspacePaths: [], useCLIVariant: false)
                                    viewModel.showInstallFeedbackPublic(count > 0 ? "Skills installed" : "Open a folder first", isError: count == 0)
                                }
                                Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                    let count = MCPIntegrationHelper.installWorkspaceSkills(workspacePaths: [], useCLIVariant: true)
                                    viewModel.showInstallFeedbackPublic(count > 0 ? "Skills installed" : "Open a folder first", isError: count == 0)
                                }
                                Divider()
                                Button("Uninstall") {
                                    let count = MCPIntegrationHelper.uninstallWorkspaceSkills(workspacePaths: [], useCLIVariant: false)
                                    let cliCount = MCPIntegrationHelper.uninstallWorkspaceSkills(workspacePaths: [], useCLIVariant: true)
                                    viewModel.showInstallFeedbackPublic(count + cliCount > 0 ? "Skills removed" : "Nothing to remove")
                                }
                            }
                        }

                        Section {
                            Text("Codex CLI (~/.codex/prompts)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Menu("Global") {
                                Button("MCP skills") {
                                    let count = MCPIntegrationHelper.installCodexCommands(useCLIVariant: false)
                                    viewModel.showInstallFeedbackPublic(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                                }
                                Button("\(MCPIntegrationHelper.cliCommandName) skills") {
                                    let count = MCPIntegrationHelper.installCodexCommands(useCLIVariant: true)
                                    viewModel.showInstallFeedbackPublic(count > 0 ? "Skills installed" : "Install failed", isError: count == 0)
                                }
                                Divider()
                                Button("Uninstall") {
                                    let count = MCPIntegrationHelper.uninstallCodexCommands(useCLIVariant: false)
                                    let cliCount = MCPIntegrationHelper.uninstallCodexCommands(useCLIVariant: true)
                                    viewModel.showInstallFeedbackPublic(count + cliCount > 0 ? "Skills removed" : "Nothing to remove")
                                }
                            }
                        }
                    } label: {
                        Label("Skills", systemImage: "terminal")
                    }
                    .buttonStyle(CustomButtonStyle())

                    Menu {
                        Button("Install \(MCPIntegrationHelper.cliCommandName)") { viewModel.installCLI() }
                            .disabled(viewModel.cliInstallStatus == .installed)
                        Button("Install \(CLIPathInstaller.claudeRPCommandName)") { viewModel.installClaudeRP() }
                            .disabled(viewModel.claudeRPInstallStatus == .installed)
                    } label: {
                        Label("CLI Tools...", systemImage: "apple.terminal")
                    }
                    .buttonStyle(CustomButtonStyle())

                    Spacer()

                    Text("Configure the MCP server")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        viewModel.openMCPServerPopover(windowID: windowID)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "server.rack")
                                .foregroundColor(.green)
                            Text("MCP Server")
                        }
                    }
                    .buttonStyle(CustomButtonStyle())
                }

                // Feedback
                if let feedback = viewModel.installFeedback {
                    Text(feedback)
                        .foregroundColor(viewModel.installFeedbackIsError ? .orange : .green)
                        .transition(.opacity)
                }
            }

            // Key advantages
            VStack(spacing: 12) {
                MCPAdvantageRow(
                    icon: "bolt.fill",
                    title: "~80% Fewer Tokens",
                    description: "Smart file search, code structure, and editing tools use a fraction of the tokens compared to built-in equivalents.",
                    color: .yellow
                )

                MCPAdvantageRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Intelligent Context Building",
                    description: "Two-stage pipeline: a Context Builder agent finds relevant files, then an analysis model produces deep plans, reviews, or answers.",
                    color: .blue
                )

                MCPAdvantageRow(
                    icon: "terminal.fill",
                    title: "Workflow Skills",
                    description: "Ready-made slash commands like /rp-build, /rp-review, and /rp-investigate \u{2014} deep context engineering pipelines your agents run directly.",
                    color: .purple
                )

                MCPAdvantageRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Works Everywhere",
                    description: "Claude Code, Cursor, VS Code, Codex CLI, OpenCode, Claude Desktop \u{2014} install in any MCP client with one click.",
                    color: .green
                )
            }
        }
        .onAppear {
            viewModel.refreshInstallStatuses()
        }
    }
}

/// A single MCP advantage row for the sales pitch.
private struct MCPAdvantageRow: View {
    let icon: String
    let title: String
    let description: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.02))
        )
    }
}

// MARK: - Step: CLI Providers (Both tiers)

private struct ProvidersStepView: View {
    @ObservedObject var viewModel: AgentOnboardingWizardViewModel
    let windowID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Recommendations banner at top
            HStack(spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Once your providers are configured, run the Setup Wizard to auto-configure models in the app.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button(action: {
                    var userInfo: [String: Any] = [:]
                    if let id = windowID { userInfo["windowID"] = id }
                    NotificationCenter.default.post(name: .showRecommendationWizard, object: nil, userInfo: userInfo)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb")
                            .foregroundColor(.yellow)
                        Text("Setup Wizard")
                    }
                }
                .buttonStyle(CustomButtonStyle())
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.yellow.opacity(0.06))
            )

            Text("Connect your CLI tools below — each one uses your existing provider account or local runtime. These providers power Agent Mode and Context Builder workflows.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                CompactProviderRow(
                    name: "Codex CLI",
                    icon: "star.fill",
                    description: "Native app server — full agent control, compaction, and session management",
                    isConnected: viewModel.codexConnected,
                    isLoading: viewModel.isLoadingCodex,
                    errorText: viewModel.codexError,
                    setupHint: "Run 'codex' in terminal",
                    isRecommended: true,
                    requiresPro: false,
                    onTest: { viewModel.testCodex() }
                )

                CompactProviderRow(
                    name: "Claude Code",
                    icon: "terminal",
                    description: "Headless CLI via MCP — context tools and editing, session management",
                    isConnected: viewModel.claudeCodeConnected,
                    isLoading: viewModel.isLoadingClaudeCode,
                    errorText: viewModel.claudeCodeError,
                    setupHint: "Run 'claude login' in terminal",
                    isRecommended: false,
                    requiresPro: false,
                    onTest: { viewModel.testClaudeCode() }
                )

                CompactProviderRow(
                    name: "OpenCode",
                    icon: "terminal",
                    description: "Headless CLI via MCP — context tools and editing, session management",
                    isConnected: viewModel.openCodeConnected,
                    isLoading: viewModel.isLoadingOpenCode,
                    errorText: viewModel.openCodeError,
                    setupHint: "Run 'opencode' in terminal",
                    isRecommended: false,
                    requiresPro: false,
                    onTest: { viewModel.testOpenCode() }
                )

                CompactProviderRow(
                    name: "Cursor",
                    icon: "cursorarrow",
                    description: "Cursor ACP runtime — Agent Mode, Context Builder, and chat via Cursor CLI",
                    isConnected: viewModel.cursorConnected,
                    isLoading: viewModel.isLoadingCursor,
                    errorText: viewModel.cursorError,
                    setupHint: "Install Cursor CLI and sign in",
                    isRecommended: false,
                    requiresPro: false,
                    onTest: { viewModel.testCursor() }
                )
            }
        }
    }
}

// MARK: - Step: Completion

private struct CompletionStepView: View {
    @ObservedObject var viewModel: AgentOnboardingWizardViewModel
    let windowID: Int?
    let canContinueToMain: Bool
    let onExit: () -> Void

    @State private var showCheckmark = false
    @State private var showActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 100, height: 100)
                        .scaleEffect(showCheckmark ? 1 : 0.5)

                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.green, .green.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .scaleEffect(showCheckmark ? 1 : 0)
                        .opacity(showCheckmark ? 1 : 0)
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1), value: showCheckmark)
                Spacer()
            }

            Text("You're all set! Here are some things to try:")
                .font(.title3)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(showActions ? 1 : 0)

            VStack(spacing: 14) {
                // Continue into the main app
                if canContinueToMain {
                    QuickActionRow(
                        icon: "terminal",
                        title: "Start using Agent sessions",
                        description: "Open the main Agent workspace"
                    ) {
                        onExit()
                    }
                }

                QuickActionRow(
                    icon: "book",
                    title: "Explore Workflow Docs",
                    description: "Learn about slash commands and workflows"
                ) {
                    viewModel.openWorkflowDocs()
                }
            }
            .opacity(showActions ? 1 : 0)
            .offset(y: showActions ? 0 : 20)
        }
        .onAppear {
            showCheckmark = true
            withAnimation(.easeOut(duration: 0.4).delay(0.5)) {
                showActions = true
            }
        }
    }
}

// MARK: - Shared Components

private struct AnimatedFeatureRow: View {
    let icon: String
    let title: String
    let description: String
    let delay: Double
    @Binding var appeared: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
        .offset(x: appeared ? 0 : 30)
        .opacity(appeared ? 1 : 0)
    }
}

private struct PipelineStageCard: View {
    let stage: String
    let title: String
    let description: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.12))
                    .frame(width: 50, height: 50)
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(stage)
                        .font(.subheadline.bold())
                        .foregroundColor(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(color.opacity(0.12))
                        )
                    Text(title)
                        .font(.headline)
                }

                Text(description)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct CompactProviderRow: View {
    let name: String
    let icon: String
    let description: String
    let isConnected: Bool
    let isLoading: Bool
    let errorText: String?
    let setupHint: String
    let isRecommended: Bool
    let requiresPro: Bool
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.headline)

                    if isRecommended {
                        Text("Recommended")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }

                    if requiresPro {
                        Text("Pro")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                    }
                }

                Text(description)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isConnected {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Connected")
                        .bold()
                        .foregroundColor(.green)
                }
            } else if let error = errorText {
                Text(error)
                    .foregroundColor(.red)
                    .lineLimit(1)
            } else {
                Text(setupHint)
                    .foregroundColor(.secondary)
            }

            Button(isConnected ? "Test" : "Connect", action: onTest)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isLoading)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isRecommended ? Color.accentColor.opacity(0.04) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isRecommended ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if isConnected { return .green }
        if errorText != nil { return .orange }
        return .gray.opacity(0.5)
    }
}

private struct ProFeatureItem: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentColor)
                .frame(width: 18)
            Text(label)
                .font(.caption)
            Spacer()
        }
    }
}

private struct QuickActionRow: View {
    let icon: String
    let title: String
    let description: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(description)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.body)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct AgentOnboardingWizardView_Previews: PreviewProvider {
        static var previews: some View {
            Text("AgentOnboardingWizardView - requires app context")
                .frame(width: 560, height: 520)
        }
    }
#endif
