import AppKit
import Combine
import RepoPromptProviderQuota
import RepoPromptSettingsCore
import SwiftUI

// SEARCH-HELPER: provider usage limits settings UI, account quota section, observe-only,
// usage limits master toggle, Connect Claude usage, Codex usage source
//
// One generic, observe-only plan-usage surface shared by every first-party provider card.
//
// Three independent settings meet here and none implies another:
//  - The master presentation switch ("Show usage limits when available", Agent Mode Overview)
//    only decides whether usage is shown at all.
//  - Each provider's *source* must be enabled (Codex app server) or explicitly connected
//    (Claude account usage, per config profile) before anything is acquired.
//  - The legacy passive Claude run telemetry is diagnostics only and lives under Details.
//
// The view body never switches on provider: per-provider copy and source control are resolved
// once into a `ProviderUsageSectionConfiguration`. Account-scoped plan usage is deliberately
// not mixed with per-session context-window usage.

enum ProviderQuotaSettingsTarget: Hashable {
    case codex
    case claude

    /// Only first-party agents own account usage. Claude-compatible launchers and every other
    /// provider map to `nil`, so no indicator is shown for them.
    init?(agent: AgentProviderKind) {
        switch agent {
        case .codexExec: self = .codex
        case .claudeCode: self = .claude
        default: return nil
        }
    }
}

/// Settings writes to the master switch must reach the one runtime shared by every window.
/// Swappable so MCP/settings tests can assert transitions without a runtime.
@MainActor
enum UsageLimitsDisplayRuntimeBridge {
    static var applyEnabled: (Bool) -> Void = { enabled in
        WindowStatesManager.shared.providerQuotaRuntime.applyUsageDisplayEnabled(enabled)
    }
}

// MARK: - Pure configuration primitives (unit-tested)

struct ProviderUsageConsentCopy: Equatable {
    let title: String
    let message: String
    let confirmTitle: String
}

/// Everything provider-specific the generic section needs, resolved once.
struct ProviderUsageSectionConfiguration {
    let displayName: String
    /// One sentence shown in Details, e.g. where readings come from.
    let sourceSentence: String
    let detailLines: [String]
    let sourceState: ProviderUsageSourceState
    let consent: ProviderUsageConsentCopy?
    let activateSource: @MainActor () -> Void
    let deactivateSource: @MainActor () -> Void
    /// Optional diagnostics-only toggle rendered inside Details.
    let diagnosticsToggle: ProviderUsageDiagnosticsToggle?
    var prepareSetup: (@MainActor () async throws -> URL)?
    var completeSetup: (@MainActor () async throws -> Void)?

    static let observeOnlyLine = "Read-only. Never changes which model runs."

    static let claudeConsent = ProviderUsageConsentCopy(
        title: "Connect Claude usage?",
        message: "One-time setup opens Claude Code in Terminal so you can approve its helper folder or sign in. Quit Claude when ready, then click Check usage after setup here. After setup, RepoPrompt runs Claude Code in the background to open /usage. RepoPrompt does not read login tokens, send model prompts, or edit your Claude settings. Only usage percentages and reset times are cached on this Mac. This uses documented CLI features, but Anthropic has not explicitly approved automated usage monitoring. This is optional, and you can disconnect at any time.",
        confirmTitle: "Connect and open setup"
    )
}

struct ProviderUsageDiagnosticsToggle {
    let title: String
    let isOn: Binding<Bool>
}

// MARK: - Section

struct ProviderUsageQuotaSection: View {
    enum Style {
        /// Full card section in Settings › CLI Providers.
        case settings
        /// Agent Mode pill popover: rows, Refresh, and a link to Settings only.
        case popover
    }

    let provider: ProviderQuotaSettingsTarget
    let style: Style
    var openSettings: (() -> Void)?

    @State private var surfaceID = UUID()
    @State private var claudeProfileID: String?
    @State private var showsConsent = false
    @State private var showsDetails = false
    @State private var showsSetup = false
    @State private var setupError: String?
    @State private var setupWasOpened = false
    @ObservedObject private var store: ProviderQuotaUIStore
    @ObservedObject private var settingsStore = GlobalSettingsStore.shared

    @MainActor
    init(
        provider: ProviderQuotaSettingsTarget = .codex,
        style: Style = .settings,
        store: ProviderQuotaUIStore? = nil,
        openSettings: (() -> Void)? = nil
    ) {
        self.provider = provider
        self.style = style
        self.openSettings = openSettings
        let runtime = WindowStatesManager.shared.providerQuotaRuntime
        _store = ObservedObject(wrappedValue: store ?? (provider == .codex ? runtime.codexUI : runtime.claudeUI))
    }

    var body: some View {
        let configuration = makeConfiguration()
        VStack(alignment: .leading, spacing: 8) {
            if style == .settings {
                Text("Plan usage")
                    .font(.system(size: 11, weight: .semibold))
            }

            if !settingsStore.usageLimitsDisplayEnabled() {
                Text("Usage limits are hidden. Turn on “Show usage limits when available” in Agent Mode › Overview.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                switch configuration.sourceState {
                case let .inactive(activateTitle, explanation, requiresConsent):
                    inactiveSource(
                        configuration: configuration,
                        activateTitle: activateTitle,
                        explanation: explanation,
                        requiresConsent: requiresConsent
                    )
                case .active:
                    readings
                    if style == .settings, setupWasOpened, let completeSetup = configuration.completeSetup {
                        Text("Approve folder trust or sign in in Claude, then quit Claude and check usage here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Check usage after setup") {
                            Task { @MainActor in
                                do { try await completeSetup()
                                    setupWasOpened = false
                                } catch { setupError = (error as? ProviderQuotaReadError)?.message ?? "Could not check Claude usage." }
                            }
                        }
                        .buttonStyle(CustomButtonStyle())
                        .font(.caption)
                    } else if style == .settings, configuration.prepareSetup != nil, offersSetup {
                        Text("If Claude needs folder trust or sign-in, finish setup once, then check usage here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { showsSetup = true } label: {
                            Label("Finish Claude setup…", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(CustomButtonStyle())
                        .font(.caption)
                    }
                    footer(configuration: configuration)
                }
            }
        }
        .onAppear {
            if provider == .claude {
                // Resolved once per appearance, never from the body.
                claudeProfileID = WindowStatesManager.shared.providerQuotaRuntime.currentClaudeUsageProfileID
            }
            store.activate(surfaceID: surfaceID)
        }
        .onDisappear { store.deactivate(surfaceID: surfaceID) }
        .confirmationDialog(
            configuration.consent?.title ?? "",
            isPresented: $showsConsent,
            titleVisibility: .visible
        ) {
            Button(configuration.consent?.confirmTitle ?? "Connect") {
                configuration.activateSource()
                if configuration.prepareSetup != nil { openSetup(configuration: configuration) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(configuration.consent?.message ?? "")
        }
        .confirmationDialog("Set up Claude usage?", isPresented: $showsSetup, titleVisibility: .visible) {
            Button("Open Terminal") { openSetup(configuration: configuration) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This one-time setup opens Claude Code in Terminal so you can approve its helper folder or sign in. Quit Claude when ready, then click Check usage after setup here. RepoPrompt will not accept prompts or send a model message for you.")
        }
        .alert("Claude usage setup", isPresented: Binding(get: { setupError != nil }, set: { if !$0 { setupError = nil } })) {
            Button("OK") { setupError = nil }
        } message: { Text(setupError ?? "") }
    }

    private var offersSetup: Bool {
        switch store.state {
        case .hidden, .idle, .unavailable: true
        case .loading, .loaded: false
        }
    }

    @MainActor
    private func openSetup(configuration: ProviderUsageSectionConfiguration) {
        Task { @MainActor in
            do {
                guard let prepare = configuration.prepareSetup else { return }
                let script = try await prepare()
                guard NSWorkspace.shared.open(script) else { throw ProviderQuotaReadError.cliUnavailable }
                setupWasOpened = true
            } catch { setupError = (error as? ProviderQuotaReadError)?.message ?? "Could not open Claude usage setup." }
        }
    }

    // MARK: Configuration (the only provider-specific code)

    @MainActor
    private func makeConfiguration() -> ProviderUsageSectionConfiguration {
        switch provider {
        case .codex:
            return ProviderUsageSectionConfiguration(
                displayName: "Codex",
                sourceSentence: "Reads your Codex plan limits from the Codex app server.",
                detailLines: ["Updates from the app server while usage is on screen."],
                sourceState: .codex(enabled: settingsStore.codexUsageQuotaEnabled()),
                consent: nil,
                activateSource: {
                    GlobalSettingsStore.shared.setCodexUsageQuotaEnabled(true)
                    CodexUsageQuotaRuntimeBridge.applyEnabled(true)
                },
                deactivateSource: {
                    GlobalSettingsStore.shared.setCodexUsageQuotaEnabled(false)
                    CodexUsageQuotaRuntimeBridge.applyEnabled(false)
                },
                diagnosticsToggle: nil
            )
        case .claude:
            var lines = ["Checks once after launch when usage is shown, and when you press Refresh. No periodic polling.", "Cached readings may be older than your current usage. Account identity is not verified.", "If Claude asks for helper-folder trust or sign-in, use Open Claude setup. Claude may retain its own normal session bookkeeping."]
            if let claudeProfileID, !claudeProfileID.isEmpty {
                lines.append("Profile: \((claudeProfileID as NSString).abbreviatingWithTildeInPath)")
            }
            if let grant = settingsStore.claudeCLIUsageGrant() {
                lines.append("Connected \(grant.grantedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            return ProviderUsageSectionConfiguration(
                displayName: "Claude",
                sourceSentence: "Reads your Claude plan limits through Claude Code’s /usage command.",
                detailLines: lines,
                sourceState: .claude(
                    grant: settingsStore.claudeCLIUsageGrant(),
                    currentProfileID: claudeProfileID
                ),
                consent: ProviderUsageSectionConfiguration.claudeConsent,
                activateSource: { WindowStatesManager.shared.providerQuotaRuntime.connectClaudeUsage(startReading: false) },
                deactivateSource: { WindowStatesManager.shared.providerQuotaRuntime.disconnectClaudeUsage() },
                diagnosticsToggle: ProviderUsageDiagnosticsToggle(
                    title: "Record rate-limit events from Claude runs (diagnostics)",
                    isOn: Binding(
                        get: { GlobalSettingsStore.shared.claudeUsageQuotaEnabled() },
                        set: { enabled in
                            GlobalSettingsStore.shared.setClaudeUsageQuotaEnabled(enabled)
                            ClaudeUsageQuotaRuntimeBridge.applyEnabled(enabled)
                        }
                    )
                ),
                prepareSetup: { try await WindowStatesManager.shared.providerQuotaRuntime.prepareClaudeUsageSetup() },
                completeSetup: { try await WindowStatesManager.shared.providerQuotaRuntime.completeClaudeUsageSetup() }
            )
        }
    }

    // MARK: Inactive source

    @ViewBuilder
    private func inactiveSource(
        configuration: ProviderUsageSectionConfiguration,
        activateTitle: String,
        explanation: String,
        requiresConsent: Bool
    ) -> some View {
        Text(explanation)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if style == .settings {
            Button(activateTitle) {
                if requiresConsent {
                    showsConsent = true
                } else {
                    configuration.activateSource()
                }
            }
            .buttonStyle(CustomButtonStyle())
            .font(.caption)
        } else if let openSettings {
            // Consent is only ever granted from Settings, never from a transient popover.
            Button("Usage settings…", action: openSettings)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    // MARK: Readings

    @ViewBuilder
    private var readings: some View {
        switch store.state {
        case .hidden:
            EmptyView()

        case let .idle(message), let .unavailable(message):
            // Never a zero, never an empty bar.
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 12)
                Text("Loading…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case let .loaded(sections, footnote, accountNotice):
            VStack(alignment: .leading, spacing: 10) {
                if let accountNotice {
                    Label(accountNotice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(sections) { section in
                    ProviderQuotaBucketView(section: section, showsTitle: sections.count > 1)
                }

                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Footer: Refresh + Details

    @ViewBuilder
    private func footer(configuration: ProviderUsageSectionConfiguration) -> some View {
        HStack(spacing: 10) {
            Button(action: { store.refresh() }) {
                if store.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(height: 12)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .disabled(store.isRefreshing || store.state == .hidden)
            .buttonStyle(CustomButtonStyle())

            Spacer(minLength: 8)

            if style == .settings {
                Button(showsDetails ? "Hide details" : "Details") { showsDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            } else if let openSettings {
                Button("Usage settings…", action: openSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }

        if style == .settings, showsDetails {
            details(configuration: configuration)
        }
    }

    private func details(configuration: ProviderUsageSectionConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(configuration.sourceSentence + " " + ProviderUsageSectionConfiguration.observeOnlyLine)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(configuration.detailLines, id: \.self) { line in
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
            if let diagnosticsToggle = configuration.diagnosticsToggle {
                Toggle(diagnosticsToggle.title, isOn: diagnosticsToggle.isOn)
                    .toggleStyle(.checkbox)
            }
            if case let .active(deactivateTitle) = configuration.sourceState {
                if configuration.prepareSetup != nil {
                    Button("Open Claude setup…") { showsSetup = true }
                        .buttonStyle(CustomButtonStyle())
                }
                Button(deactivateTitle) { configuration.deactivateSource() }
                    .buttonStyle(.link)
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.leading, 2)
    }
}

// MARK: - Shared row views (Settings and Agent Mode popover)

struct ProviderQuotaBucketView: View {
    let section: ProviderQuotaBucketSection
    /// A single account-wide bucket needs no extra heading under "Plan usage".
    let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsTitle || section.statusText != nil {
                HStack(spacing: 6) {
                    if showsTitle {
                        Text(section.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }
                    // Bucket-level status accompanies the real per-window figures rather than
                    // overwriting them.
                    if let statusText = section.statusText {
                        Text(statusText)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            ForEach(section.rows) { row in
                ProviderQuotaWindowRowView(row: row)
            }
        }
    }
}

struct ProviderQuotaWindowRowView: View {
    let row: ProviderQuotaWindowRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 8)
                // The printed figure is never clamped, even above a declared bound.
                Text(row.valueText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(row.isReached ? .orange : .primary)
            }

            // A bar is drawn only when there is a real value; the bar clamps, the text does not.
            if let barFraction = row.barFraction {
                ProgressView(value: barFraction)
                    .progressViewStyle(.linear)
                    .tint(row.isReached ? .orange : .accentColor)
                    .frame(height: 3)
            }

            if let detailText = row.detailText {
                Text(detailText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
