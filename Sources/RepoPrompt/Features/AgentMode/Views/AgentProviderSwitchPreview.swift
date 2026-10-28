import SwiftUI

/// Keep the populated composer as a stable sheet host even when no session/banner exists.
struct AgentProviderSwitchPresentation<Content: View>: View {
    @ObservedObject var viewModel: AgentModeViewModel
    let tabID: UUID?
    let content: Content

    var body: some View {
        VStack(spacing: 8) {
            if let tabID, let session = viewModel.sessions[tabID] {
                AgentProviderSwitchBanner(viewModel: viewModel, session: session)
            }
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

private struct AgentProviderSwitchBanner: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @ObservedObject var session: AgentTabSession

    var body: some View {
        Group {
            if session.pendingHandoff.providerSwitchDelivery != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if AgentModeViewModel.providerSwitchUnconfirmed(session) {
                        Text("Switch not confirmed").font(.headline)
                        Text("\(session.selectedAgent.displayName) may already have the handover.")
                        Text("Your last message won't be resent.")
                        if let error = session.items.last(where: { $0.kind == .error })?.text {
                            Text(error).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Review") {
                            viewModel.requestProviderSwitchBannerAction(for: session, discard: false)
                        }
                        Button("Discard handover") {
                            viewModel.requestProviderSwitchBannerAction(for: session, discard: true)
                        }
                    }
                    .disabled(viewModel.providerSwitchMutation != nil)
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
            }
        }
    }
}

struct AgentProviderSwitchPreview: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @State private var showsPayload = false
    @State private var payload = ""

    var body: some View {
        if let preview = viewModel.providerSwitchPreview {
            VStack(alignment: .leading, spacing: 14) {
                Text("Switch to \(preview.destination.displayName) / \(viewModel.inputBarModelDisplayName(rawModel: preview.model, agentKind: preview.destination))")
                    .font(.headline)
                if preview.updated { Text("Preview updated.").foregroundStyle(.secondary) }
                if preview.building { ProgressView() }
                if preview.choices.first?.unavailable != nil { Text("Full history doesn't fit.") }
                ForEach(preview.choices.filter { !$0.hidden }, id: \.mode.rawValue) { choice in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Button {
                                viewModel.providerSwitchPreview?.selected = choice.mode
                                showsPayload = false
                                payload = ""
                            } label: {
                                Label(choice.label, systemImage: preview.selected == choice.mode ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(choice.unavailable != nil || choice.bytes == 0 || preview.generationItemID != nil)
                            Spacer()
                            if choice.mode == .summary, !preview.isReview {
                                Button(preview.generationItemID == nil ? "Generate" : "Generating…") {
                                    Task { await viewModel.generateProviderSwitchHandover(preview.id) }
                                }
                                .disabled(preview.wordLimit == nil || preview.generationItemID != nil || viewModel.providerSwitchPreviewBlocker(preview) != nil)
                            }
                        }
                        if choice.mode == .summary, !preview.isReview {
                            Text("Runs one turn on \(preview.sourceAgent.displayName).").foregroundStyle(.secondary)
                        }
                        if choice.mode != .history, let reason = choice.unavailable { Text("Unavailable: \(reason)").foregroundStyle(.secondary) }
                        if choice.bytes > 0, let budget = preview.budget {
                            let tokens = Int((AgentProviderHandover.estimate(bytes: choice.bytes) + budget.instructionTokens + budget.inputTokens).rounded(.up))
                            if budget.windowSource == .assumed {
                                Text("~\(tokens) of 128K tokens (assumed)")
                            } else { Text("~\(tokens) of \(budget.window) tokens") }
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
                .task(id: "\(preview.id)-\(preview.selected?.rawValue ?? "")-\(showsPayload)") {
                    payload = ""
                    if showsPayload, let mode = preview.selected {
                        let rendered = await viewModel.providerSwitchPayload(preview.id, mode: mode)
                        guard !Task.isCancelled, viewModel.providerSwitchPreview?.id == preview.id,
                              viewModel.providerSwitchPreview?.selected == mode else { return }
                        payload = rendered ?? ""
                    }
                }
                if let reason = viewModel.providerSwitchPreviewBlocker(preview) { Text("Can't switch: \(reason)").foregroundStyle(.secondary) }
                HStack {
                    if preview.isReview {
                        Button("Discard handover") { Task { await viewModel.applyProviderSwitch(preview.id, discard: true) } }
                            .disabled(viewModel.providerSwitchDiscardBlocker(preview) != nil || viewModel.providerSwitchMutation != nil)
                    }
                    Spacer()
                    Button("Cancel") { viewModel.cancelProviderSwitchPreview() }.keyboardShortcut(.cancelAction)
                        .disabled(viewModel.providerSwitchMutation != nil)
                    Button("Switch") { Task { await viewModel.applyProviderSwitch(preview.id) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview.building || preview.selected == nil || preview.chosen?.unavailable != nil || preview.chosen?.bytes ?? 0 == 0 || preview.generationItemID != nil || viewModel.providerSwitchPreviewBlocker(preview) != nil || viewModel.providerSwitchMutation != nil)
                }
            }
            .padding(20)
            .frame(width: 580)
            .interactiveDismissDisabled(viewModel.providerSwitchMutation != nil)
        }
    }
}
