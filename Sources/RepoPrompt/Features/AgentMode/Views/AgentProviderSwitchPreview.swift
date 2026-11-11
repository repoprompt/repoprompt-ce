import SwiftUI

/// Keep the populated composer as a stable sheet host even when no session/banner exists.
struct AgentProviderSwitchPresentation<Content: View>: View {
    @ObservedObject var viewModel: AgentModeViewModel
    let tabID: UUID?
    let content: Content
    @Binding var bannerHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let tabID, let session = viewModel.sessions[tabID] {
                    AgentProviderSwitchBanner(viewModel: viewModel, session: session)
                }
            }
            .background(GeometryReader { geometry in
                Color.clear.onAppear { bannerHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in bannerHeight = height }
            })
            content
        }
        .sheet(isPresented: Binding(
            get: {
                guard let tabID, let session = viewModel.sessions[tabID],
                      let preview = viewModel.providerSwitchPreview else { return false }
                return preview.session === session
            },
            set: { if !$0 { viewModel.cancelProviderSwitchPreview() } }
        )) {
            AgentProviderSwitchPreview(viewModel: viewModel)
        }
    }
}

private extension View {
    func providerSwitchBannerStyle() -> some View {
        font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
    }
}

private struct AgentProviderSwitchBanner: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @ObservedObject var session: AgentTabSession

    var body: some View {
        if viewModel.providerSwitchIsCompletingInBackground(session) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Finishing change…")
            }
            .providerSwitchBannerStyle()
        }
        if let outcome = viewModel.providerSwitchBackgroundOutcome,
           outcome.session === session, outcome.binding == session.currentRestorationBindingToken
        {
            HStack {
                Text("Change didn't finish. Check this chat before trying again.")
                Button("OK") { viewModel.providerSwitchBackgroundOutcome = nil }
            }
            .providerSwitchBannerStyle()
        }
        if session.pendingHandoff.providerSwitchDelivery != nil {
            VStack(alignment: .leading, spacing: 6) {
                if AgentModeViewModel.providerSwitchUnconfirmed(session) {
                    Text("Switch not confirmed").font(.headline)
                    Text("\(session.selectedAgent.displayName) may already have the handover.")
                    Text("Your last message may be included in the handover history, and the new provider may act on it.")
                }
                HStack {
                    Button("Review") {
                        viewModel.requestProviderSwitchBannerAction(for: session, discard: false)
                    }
                    Button("Discard handover") {
                        viewModel.requestProviderSwitchBannerAction(for: session, discard: true)
                    }
                    .disabled(viewModel.providerSwitchDiscardBlocker(session) != nil)
                }
                .disabled(viewModel.providerSwitchMutation != nil)
            }
            .providerSwitchBannerStyle()
        }
    }
}

struct AgentProviderSwitchPreview: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @State private var showsPayload = false
    @State private var payload = ""
    /// Local arm state only — never persisted. Keyed on switch identity so a same-identity
    /// preview rebuild keeps the arm but a different destination/model/session drops it.
    @State private var armedPreviewKey: String?

    private func forceKey(_ preview: AgentModeViewModel.ProviderSwitchPreview) -> String {
        "\(preview.session.tabID.uuidString)|\(preview.destination.rawValue)|\(preview.model)|\(preview.isReview)"
    }

    /// View-only copy: never echo transport errors or agent-directed refusal text.
    static func blockerText(_ reason: String) -> String {
        if reason == AgentSessionLinkSendFailure.providerHandoverNeedsReview.message {
            return "The handover needs review. Cancel and review it again, or discard it when available."
        }
        return "Switch is unavailable while this chat is busy or needs attention. You can cancel and try again later."
    }

    static func unavailableText(_ reason: String) -> String {
        switch reason {
        case "the last turn alone doesn't fit": "The last turn alone doesn't fit."
        case "no room for a summary": "There is no room for a summary."
        case "the summary is too large": "The summary is too large."
        case "the model used tools": "The summary couldn't be used because the model used tools."
        default: "This handover option is unavailable."
        }
    }

    static func visibleChoices(_ choices: [AgentModeViewModel.ProviderSwitchChoice]) -> [AgentModeViewModel.ProviderSwitchChoice] {
        choices.filter { !$0.hidden && !($0.mode == .history && $0.unavailable != nil) }
    }

    static func tokenEstimateText(bytes: Int, budget: AgentProviderHandover.Budget) -> String {
        let tokens = Int((AgentProviderHandover.estimate(bytes: bytes) + budget.instructionTokens + budget.inputTokens).rounded(.up))
        return "~\(tokens) tokens"
    }

    var body: some View {
        if let preview = viewModel.providerSwitchPreview {
            VStack(alignment: .leading, spacing: 14) {
                Text("Switch to \(preview.destination.displayName) / \(viewModel.inputBarModelDisplayName(rawModel: preview.model, agentKind: preview.destination))")
                    .font(.headline)
                if preview.updated { Text("Preview updated.").foregroundStyle(.secondary) }
                if preview.building { ProgressView() }
                ForEach(Self.visibleChoices(preview.choices), id: \.mode.rawValue) { choice in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Button {
                                viewModel.selectProviderSwitchChoice(choice.mode, previewID: preview.id)
                                showsPayload = false
                                payload = ""
                            } label: {
                                Label(choice.label, systemImage: preview.selected == choice.mode ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(choice.unavailable != nil || choice.bytes == 0 || preview.generationItemID != nil)
                            Spacer()
                        }
                        if choice.mode != .history, let reason = choice.unavailable { Text(Self.unavailableText(reason)).foregroundStyle(.secondary) }
                        if choice.bytes > 0, let budget = preview.budget {
                            Text(Self.tokenEstimateText(bytes: choice.bytes, budget: budget))
                        }
                        if let omissions = choice.omissions { Text("Not included: \(omissions)").foregroundStyle(.secondary) }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(preview.selected == choice.mode ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
                }
                DisclosureGroup("Show handover", isExpanded: $showsPayload) {
                    ScrollView { Text(payload).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 180)
                }
                .disabled(preview.chosen?.bytes ?? 0 == 0)
                .onChange(of: preview.id) {
                    // A same-identity rebuild (streaming drift, refreshed choices) keeps the arm;
                    // a different destination/model/session drops it.
                    if armedPreviewKey != forceKey(preview) { armedPreviewKey = nil }
                }
                .task(id: "\(preview.id)-\(preview.selected?.rawValue ?? "")-\(showsPayload)") {
                    payload = ""
                    if showsPayload, let mode = preview.selected {
                        let rendered = await viewModel.providerSwitchPayload(preview.id, mode: mode)
                        guard !Task.isCancelled, viewModel.providerSwitchPreview?.id == preview.id,
                              viewModel.providerSwitchPreview?.selected == mode else { return }
                        payload = rendered ?? ""
                    }
                }
                let admission = viewModel.providerSwitchPreviewAdmission(preview)
                if case let .forceable(cause) = admission, !preview.isReview {
                    let provider = preview.sourceAgent.displayName
                    // The force buttons carry the same payload-readiness gates as Switch; the
                    // apply guard refuses anything they miss, so keep them aligned.
                    let forceUnavailable = preview.building || preview.selected == nil
                        || preview.chosen?.unavailable != nil || preview.chosen?.bytes ?? 0 == 0
                        || preview.generationItemID != nil || viewModel.providerSwitchMutation != nil
                    VStack(alignment: .leading, spacing: 5) {
                        Text(cause.message(provider: provider)).foregroundStyle(.secondary)
                        if armedPreviewKey == forceKey(preview) {
                            Text("This stops \(provider) mid-turn; whatever it was doing is dropped. The conversation carries over.")
                                .foregroundStyle(.secondary)
                            Button("Stop \(provider) and switch") {
                                armedPreviewKey = nil
                                Task { await viewModel.applyProviderSwitch(preview.id, force: true) }
                            }
                            .disabled(forceUnavailable)
                        } else {
                            Button("Stop \(provider) and switch") { armedPreviewKey = forceKey(preview) }
                                .disabled(forceUnavailable)
                        }
                    }
                } else if let reason = admission.message(provider: preview.sourceAgent.displayName) {
                    Text(Self.blockerText(reason)).foregroundStyle(.secondary)
                }
                if !preview.building, preview.failure == nil, preview.selected == nil {
                    Text(preview.isReview ? "No handover fits. You can cancel or discard it." : "No handover fits. You can cancel.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if preview.isReview {
                        Button("Discard handover") { Task { await viewModel.applyProviderSwitch(preview.id, discard: true) } }
                            .disabled(viewModel.providerSwitchDiscardBlocker(preview) != nil)
                    }
                    Spacer()
                    Button(viewModel.providerSwitchMutation?.phase == .detached || viewModel.providerSwitchMutation?.phase == .staged ? "Close" : "Cancel") {
                        viewModel.cancelProviderSwitchPreview()
                    }.keyboardShortcut(.cancelAction)
                    Button("Switch") { Task { await viewModel.applyProviderSwitch(preview.id) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview.building || preview.selected == nil || preview.chosen?.unavailable != nil || preview.chosen?.bytes ?? 0 == 0 || preview.generationItemID != nil || viewModel.providerSwitchPreviewBlocker(preview) != nil || viewModel.providerSwitchMutation != nil)
                }
            }
            .padding(20)
            .frame(width: 580)
        }
    }
}
