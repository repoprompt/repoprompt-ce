import RepoPromptSettingsCore
import SwiftUI

/// UI-only opt-in writes through the existing raw-preserving global settings authority.
struct ProviderEnvironmentFilteringSettingsView: View {
    @ObservedObject var settings: GlobalSettingsStore
    @State private var provider: AgentProviderKind = .claudeCode
    @State private var withheldDraft = ""
    @State private var passthroughDraft = ""
    @State private var withheldBaseline: [String] = []
    @State private var passthroughBaseline: [String] = []
    @State private var message: String?

    var body: some View {
        GroupBox("Provider environment filtering (opt-in)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Empty lists preserve existing authentication and toolchain behavior. Enter variable names only, separated by commas or spaces. Names are exact and case-sensitive; wildcards and values are not accepted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Withhold ambient names for all providers", text: $withheldDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Ambient environment variable names to withhold")
                Picker("Pass-through exceptions for", selection: $provider) {
                    ForEach(AgentProviderKind.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .disabled(ProviderEnvironmentNames.parsed(passthroughDraft) != passthroughBaseline)
                TextField("Allow these withheld names for this provider", text: $passthroughDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Provider environment variable pass-through names")
                Text("Applies to new provider processes, including probes and headless launches, not running sessions or interactive user terminals. Intentional app/runtime launch overrides remain available. Withholding a required ambient name can break authentication or tools; add a pass-through exception when needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Partial mitigation only: this does not cover installation/provisioning identity checks or restrict credential files, shell profiles, or other same-user capabilities.")
                    .font(.caption)
                HStack {
                    Button("Apply") { apply() }
                        .disabled(ProviderEnvironmentNames.parsed(withheldDraft) == nil || ProviderEnvironmentNames.parsed(passthroughDraft) == nil)
                    Button("Reload") { reload() }
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
        .onAppear { reload() }
        .onChange(of: provider) { _, _ in
            passthroughBaseline = settings.providerEnvironmentPassthroughNames(for: provider.rawValue)
            passthroughDraft = passthroughBaseline.joined(separator: ", ")
            message = nil
        }
    }

    private func reload() {
        withheldBaseline = settings.providerEnvironmentWithheldNames()
        passthroughBaseline = settings.providerEnvironmentPassthroughNames(for: provider.rawValue)
        withheldDraft = withheldBaseline.joined(separator: ", ")
        passthroughDraft = passthroughBaseline.joined(separator: ", ")
        message = nil
    }

    private func apply() {
        guard let withheld = ProviderEnvironmentNames.parsed(withheldDraft),
              let passthrough = ProviderEnvironmentNames.parsed(passthroughDraft)
        else { return }
        guard withheldBaseline == settings.providerEnvironmentWithheldNames(),
              passthroughBaseline == settings.providerEnvironmentPassthroughNames(for: provider.rawValue)
        else {
            message = "Settings changed elsewhere. Reload before applying."
            return
        }
        let saved = settings.setProviderEnvironmentFiltering(withheldNames: withheld, passthroughNames: passthrough, for: provider.rawValue)
        reload()
        message = saved
            ? "Saved. Takes effect on the next provider launch."
            : "Could not persist settings. Check settings storage diagnostics."
    }
}
