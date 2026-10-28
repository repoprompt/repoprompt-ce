import Combine
import RepoPromptSettingsCore
import SwiftUI

struct AgentRepromptPill: View {
    let props: AgentRepromptPillProps
    @ObservedObject var store: AgentRepromptUIStore
    let viewModel: AgentModeViewModel
    let setEnabled: (Bool, String?) -> Void
    let openSettings: () -> Void
    @State private var showingDisclosure = false
    @State private var disclosedProviderID: String?
    @State private var oneShotRequestID: UUID?
    @State private var showingHowItWorks = false
    /// The composer that opened the disclosure, captured at open time rather than at dismissal.
    @State private var disclosureSourceTabID: UUID?
    @ObservedObject private var shortcutDisplay = GlobalKeyboardShortcutsCoordinator.shared.bindingDisplay

    private var rewriteKey: String {
        shortcutDisplay.localLabel(for: .repromptDraft)
    }

    /// Model availability loads asynchronously after the pill snapshot is first built.
    /// Rebuild the snapshot when it changes so first use does not stay on "Choose a model".
    private var availableModelChanges: AnyPublisher<[AIModel], Never> {
        viewModel.promptManager?.$availableModels.dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }

    var body: some View {
        HStack(spacing: 4) {
            AgentIconTogglePill(systemImage: "wand.and.sparkles", isOn: props.isOn, isBusy: props.isPreparing) {
                if props.isOn { setEnabled(false, nil) }
                else if !props.isAvailable { openSettings() }
                else if props.requiresDisclosure {
                    disclosedProviderID = props.providerID
                    oneShotRequestID = nil
                    disclosureSourceTabID = viewModel.currentTabID
                    showingDisclosure = true
                } else { setEnabled(true, nil) }
            }
            if !props.isAvailable { modelChooser }
        }
        .hoverTooltip(props.unavailableReason ?? "Re-prompt · \(viewModel.repromptMode.displayName). Return rewrites, Return again sends\(rewriteKey.isEmpty ? "" : "; \(rewriteKey) rewrites again"). Model: \(props.modelDisplayName ?? "unavailable").", .top)
        .accessibilityLabel("Re-prompt")
        .accessibilityValue(props.isOn ? "On" : "Off")
        .contextMenu {
            AgentRepromptModelPicker(
                selection: Binding(get: { viewModel.repromptModelSelectionRaw() }, set: { viewModel.setRepromptModelRaw($0) }),
                availableModels: viewModel.configuredRepromptModels(),
                resolvedModel: viewModel.resolvedRepromptModel()
            )
            if !viewModel.repromptModelSelectionRaw().isEmpty {
                Button("Use automatic default") { viewModel.useAutomaticRepromptModel() }
            }
            Picker("Mode", selection: Binding(get: { viewModel.repromptMode }, set: { viewModel.setRepromptMode($0) })) {
                ForEach(AgentRepromptMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Include recent chat context", isOn: Binding(get: { viewModel.repromptIncludesRecentChat }, set: { viewModel.setRepromptIncludesRecentChat($0) }))
            Text("Resolved: \(props.modelDisplayName ?? "unavailable")")
            Button("Agent Models Settings", action: openSettings)
        }
        .onAppear { viewModel.syncStatusPillsUIState() }
        .onReceive(availableModelChanges) { _ in
            // @Published emits in willSet. Resolve after the new model list is stored.
            Task { @MainActor in
                await Task.yield()
                viewModel.syncStatusPillsUIState()
            }
        }
        .onReceive(store.$oneShotDisclosureRequest) { request in
            guard let request else { return }
            oneShotRequestID = request.id
            disclosedProviderID = viewModel.repromptPillProps().providerID
            disclosureSourceTabID = request.target.tabID
            showingDisclosure = true
        }
        .popover(isPresented: $showingDisclosure) { disclosure }
        .onChange(of: showingDisclosure) { _, showing in
            guard !showing else { return }
            if store.oneShotDisclosureRequest?.id == oneShotRequestID { store.oneShotDisclosureRequest = nil }
            disclosureSourceTabID = nil
        }
    }

    /// One click to a concrete model. Explicit choices are never replaced automatically.
    private var modelChooser: some View {
        Menu {
            let models = viewModel.configuredRepromptModels()
            if models.isEmpty { Text("No supported model is connected") }
            ForEach(models, id: \.rawValue) { model in
                Button(model.displayName) { viewModel.setRepromptModelRaw(model.rawValue) }
            }
            if !viewModel.repromptModelSelectionRaw().isEmpty {
                Divider()
                Button("Use automatic default") { viewModel.useAutomaticRepromptModel() }
            }
            Divider()
            Button("Agent Models Settings…", action: openSettings)
        } label: {
            Text("Choose model").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Choose Re-prompt model")
    }

    private var disclosure: some View {
        let model = viewModel.resolvedRepromptModel()
        let lines = AgentRepromptDisclosure.summary(
            modelName: model?.displayName ?? props.modelDisplayName ?? "the selected model",
            routeName: model.map { viewModel.repromptRouteName(for: $0) } ?? "its provider",
            includesRecentChat: viewModel.repromptIncludesRecentChat
        )
        return VStack(alignment: .leading, spacing: 8) {
            Text(oneShotRequestID == nil ? "Enable Re-prompt?" : "Re-prompt this message?").font(.headline)
            ForEach(lines, id: \.self) { line in
                Label { Text(line) } icon: { Image(systemName: "circle.fill").font(.system(size: 4)) }
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("How it works", isExpanded: $showingHowItWorks) {
                Text(AgentRepromptDisclosure.howItWorks(
                    rewriteKey: rewriteKey,
                    sendOriginalKey: shortcutDisplay.localLabel(for: .repromptSendOriginal)
                ))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            HStack {
                Spacer()
                Button("Cancel  ⎋") {
                    if store.oneShotDisclosureRequest?.id == oneShotRequestID { store.oneShotDisclosureRequest = nil }
                    dismissDisclosureReturningToComposer()
                }
                .keyboardShortcut(.cancelAction)
                Button(oneShotRequestID == nil ? "Enable  ↩" : "Re-prompt once  ↩") {
                    if let oneShotRequestID, let disclosedProviderID {
                        viewModel.confirmOneShotReprompt(requestID: oneShotRequestID, providerID: disclosedProviderID)
                    } else { setEnabled(true, disclosedProviderID) }
                    dismissDisclosureReturningToComposer()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }

    private func dismissDisclosureReturningToComposer() {
        let tabID = disclosureSourceTabID
        showingDisclosure = false
        guard viewModel.currentTabID == tabID else { return }
        store.requestComposerFocus(tabID: tabID)
    }
}
