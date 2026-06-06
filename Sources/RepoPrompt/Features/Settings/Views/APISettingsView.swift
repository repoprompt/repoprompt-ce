import AppKit
import SwiftUI

struct APISettingsView: View {
    @ObservedObject var viewModel: APISettingsViewModel
    let windowID: Int
    var onAPIKeyUpdated: (() -> Void)?
    var closeAction: (() -> Void)?

    @StateObject private var secureStorageRepairViewModel = SecureStorageRepairViewModel()
    @State private var showSecureStorageRepair = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isLoading = false

    @State private var isLoadingAnthropic = false
    @State private var isLoadingOpenAI = false
    @State private var isLoadingOpenAIBaseURL = false
    @State private var isLoadingOllama = false
    @State private var isLoadingGemini = false
    @State private var isLoadingAzure = false
    @State private var isLoadingDeepSeek = false
    @State private var isLoadingFireworks = false
    @State private var isLoadingGrok = false
    @State private var isLoadingGroq = false
    @State private var isLoadingZAI = false

    @State private var showOpenAIAdvanced = false
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var hasAnyValidAPIKey: Bool {
        viewModel.isAnthropicKeyValid || viewModel.isOpenAIKeyValid || viewModel.isGeminiKeyValid
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header — framing as Oracle + API Providers.
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Providers")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .semibold))

                    Text("API keys for direct model access — primarily used by the Oracle Model, built-in chat, and legacy integrations. To add CLI-backed agents (Claude Code, Codex, OpenCode, Cursor), use CLI Providers under Agent Mode.")
                        .font(fontPreset.subheadlineFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if secureStorageRepairViewModel.isAvailable {
                    SecureStorageRepairBanner {
                        showSecureStorageRepair = true
                    }
                }

                // Recommendation banner (shows when API keys are configured)
                if hasAnyValidAPIKey {
                    RecommendationSetupBanner(
                        windowID: windowID,
                        message: "API keys configured. Check recommendations to optimize your setup.",
                        closeAction: closeAction
                    )
                }

                // Anthropic
                apiKeySection(
                    title: "Anthropic API Key",
                    key: $viewModel.anthropicApiKey,
                    isValid: $viewModel.isAnthropicKeyValid,
                    saveAction: validateAndSaveAnthropicKey,
                    deleteAction: deleteAnthropicKey,
                    isLoading: isLoadingAnthropic,
                    infoURL: "https://console.anthropic.com/settings/keys",
                    customModel: $viewModel.anthropicCustomModel
                )

                Divider()
                    .padding(.horizontal, -24)

                // OpenAI
                apiKeySection(
                    title: "OpenAI API Key",
                    key: $viewModel.openAIApiKey,
                    isValid: $viewModel.isOpenAIKeyValid,
                    saveAction: validateAndSaveOpenAIKey,
                    deleteAction: deleteOpenAIKey,
                    isLoading: isLoadingOpenAI,
                    infoURL: "https://platform.openai.com/docs/overview",
                    serviceTier: $viewModel.openAIServiceTier,
                    onServiceTierChange: { viewModel.saveOpenAIServiceTier() },
                    availableModels: viewModel.availableOpenAIModels,
                    selectedModel: $viewModel.openAICustomModel
                )

                // Advanced: Custom Base URL
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showOpenAIAdvanced.toggle()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: showOpenAIAdvanced ? "chevron.down" : "chevron.right")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: fontPreset.scaledMetric(16))
                            Text("Advanced (Custom Base URL)")
                                .font(fontPreset.swiftUIFont(sizeAtNormal: 13, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.1), lineWidth: 0.5)
                    )

                    if showOpenAIAdvanced {
                        apiKeySection(
                            title: "OpenAI Base URL",
                            key: $viewModel.openAIBaseURL,
                            isValid: $viewModel.isOpenAIBaseURLValid,
                            saveAction: {
                                isLoadingOpenAIBaseURL = true
                                Task {
                                    do {
                                        let ok = try await viewModel.validateAndSaveOpenAIBaseURL()
                                        await MainActor.run {
                                            alertMessage = ok ? "OpenAI Base URL saved." : "Could not validate the Base URL."
                                            showAlert = true
                                            isLoadingOpenAIBaseURL = false
                                        }
                                    } catch {
                                        await MainActor.run {
                                            alertMessage = error.asFriendlyString()
                                            showAlert = true
                                            isLoadingOpenAIBaseURL = false
                                        }
                                    }
                                }
                            },
                            deleteAction: {
                                Task {
                                    await viewModel.resetOpenAIBaseURL()
                                    await MainActor.run {
                                        alertMessage = "OpenAI Base URL reset to default."
                                        showAlert = true
                                    }
                                }
                            },
                            isURL: true,
                            isLoading: isLoadingOpenAIBaseURL,
                            infoURL: "https://platform.openai.com/docs/api-reference/introduction",
                            caption: "Optional. Defaults to https://api.openai.com/v1. If your proxy expects a different path, include it here."
                        )
                        .padding(.leading, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, 6)

                Divider()
                    .padding(.horizontal, -24)

                // DeepSeek
                apiKeySection(
                    title: "DeepSeek API Key",
                    key: $viewModel.deepSeekApiKey,
                    isValid: $viewModel.isDeepSeekKeyValid,
                    saveAction: validateAndSaveDeepSeekKey,
                    deleteAction: deleteDeepSeekKey,
                    isLoading: isLoadingDeepSeek,
                    infoURL: "https://platform.deepseek.com/api_keys",
                    availableModels: viewModel.availableDeepSeekModels,
                    selectedModel: $viewModel.deepSeekCustomModel
                )

                Divider()
                    .padding(.horizontal, -24)

                // Fireworks AI
                apiKeySection(
                    title: "Fireworks AI API Key",
                    key: $viewModel.fireworksApiKey,
                    isValid: $viewModel.isFireworksKeyValid,
                    saveAction: validateAndSaveFireworksKey,
                    deleteAction: deleteFireworksKey,
                    isLoading: isLoadingFireworks,
                    infoURL: "https://fireworks.ai/settings/users/api-keys",
                    availableModels: viewModel.availableFireworksModels,
                    selectedModel: $viewModel.fireworksCustomModel
                )

                Divider()
                    .padding(.horizontal, -24)

                // Grok (xAI)
                apiKeySection(
                    title: "Grok (xAI) API Key",
                    key: $viewModel.grokApiKey,
                    isValid: $viewModel.isGrokKeyValid,
                    saveAction: validateAndSaveGrokKey,
                    deleteAction: deleteGrokKey,
                    isLoading: isLoadingGrok,
                    infoURL: "https://console.x.ai/",
                    availableModels: viewModel.availableGrokModels,
                    selectedModel: $viewModel.grokCustomModel
                )

                Divider()
                    .padding(.horizontal, -24)

                // Groq
                apiKeySection(
                    title: "Groq API Key",
                    key: $viewModel.groqApiKey,
                    isValid: $viewModel.isGroqKeyValid,
                    saveAction: validateAndSaveGroqKey,
                    deleteAction: deleteGroqKey,
                    isLoading: isLoadingGroq,
                    infoURL: "https://console.groq.com/keys",
                    availableModels: viewModel.availableGroqModels,
                    selectedModel: $viewModel.groqCustomModel
                )

                Divider()
                    .padding(.horizontal, -24)

                // Z.AI
                apiKeySection(
                    title: "Z.AI API Key",
                    key: $viewModel.zaiApiKey,
                    isValid: $viewModel.isZaiKeyValid,
                    saveAction: validateAndSaveZAIKey,
                    deleteAction: deleteZAIKey,
                    isLoading: isLoadingZAI,
                    infoURL: "https://z.ai/manage-apikey/apikey-list",
                    caption: "Also activates CC Zai in Agent Mode — manage it in Settings → CLI Providers.",
                    availableModels: viewModel.availableZAIModels,
                    selectedModel: $viewModel.zaiCustomModel
                )

                Divider()
                    .padding(.horizontal, -24)

                // Gemini
                apiKeySection(
                    title: "Gemini API Key",
                    key: $viewModel.geminiApiKey,
                    isValid: $viewModel.isGeminiKeyValid,
                    saveAction: validateAndSaveGeminiKey,
                    deleteAction: deleteGeminiKey,
                    isLoading: isLoadingGemini,
                    infoURL: "https://aistudio.google.com",
                    customModel: $viewModel.geminiCustomModel
                )

                Divider()
                    .padding(.horizontal, -24)

                // Azure
                azureSettingsView

                Divider()
                    .padding(.horizontal, -24)

                // Ollama
                ollamaURLView
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSecureStorageRepair) {
            SecureStorageRepairView(viewModel: secureStorageRepairViewModel) {
                Task {
                    await viewModel.loadStoredData()
                    onAPIKeyUpdated?()
                }
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("API Key Management"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func azureCustomModelPicker() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Add Custom Deployment")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text("Optionally pin a deployment")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if viewModel.availableAzureModels.isEmpty {
                Text("No deployments discovered yet. Validate to refresh.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    Picker("", selection: $viewModel.azureCustomModel) {
                        Text("None (Remove custom deployment)").tag("")
                        Divider()
                        ForEach(viewModel.availableAzureModels, id: \.id) { descriptor in
                            Text(descriptor.displayName).tag(descriptor.id)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                    .onChange(of: viewModel.azureCustomModel) { _, _ in
                        viewModel.saveAzureCustomModel()
                    }

                    if !viewModel.azureCustomModel.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    Spacer()
                }

                if viewModel.azureCustomModel.isEmpty {
                    Text("Will use highest priority deployment discovered.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let descriptor = viewModel.availableAzureModels.first(where: { $0.id == viewModel.azureCustomModel }) {
                    Text("'\(descriptor.displayName)' added to priority list.")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("'\(viewModel.azureCustomModel)' added to priority list.")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
    }

    private func apiKeySection(
        title: String,
        key: Binding<String>,
        isValid: Binding<Bool>,
        saveAction: @escaping () -> Void,
        deleteAction: @escaping () -> Void,
        isURL: Bool = false,
        isLoading: Bool,
        infoURL: String,
        caption: String? = nil,
        serviceTier: Binding<String>? = nil,
        onServiceTierChange: (() -> Void)? = nil,
        customModel: Binding<String>? = nil,
        availableModels: [String] = [],
        selectedModel: Binding<String>? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Button(action: {
                    openURL(infoURL)
                }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                if isURL {
                    TextField("Enter URL", text: key)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                } else {
                    SecureField("Enter key", text: key)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(height: 20)
                } else if isValid.wrappedValue {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }

            HStack(spacing: 10) {
                Button(action: saveAction) {
                    Text(isValid.wrappedValue ? "Change" : "Validate & Save")
                        .frame(maxWidth: .infinity)
                }
                .disabled(key.wrappedValue.isEmpty || isLoading)
                .buttonStyle(CustomButtonStyle())

                Button(action: deleteAction) {
                    Text(isURL ? "Reset to Default" : "Delete")
                        .frame(maxWidth: .infinity)
                }
                .disabled(
                    (isURL && key.wrappedValue == "http://localhost:11434") ||
                        (!isURL && key.wrappedValue.isEmpty) ||
                        isLoading
                )
                .buttonStyle(CustomButtonStyle())
            }

            // Service Tier (for OpenAI Responses API)
            if let serviceTier, title == "OpenAI API Key" {
                VStack(alignment: .leading, spacing: 8) {
                    // Global Service Tier picker (always visible)
                    HStack {
                        Text("Service Tier")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Picker("", selection: serviceTier) {
                            Text("Auto").tag("auto")
                            Text("Default").tag("default")
                            Text("Flex").tag("flex")
                            Text("Priority").tag("priority")
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 100)
                        .onChange(of: serviceTier.wrappedValue) { _, _ in
                            onServiceTierChange?()
                        }
                        Spacer()
                    }

                    Text("Flex saves cost, Priority is faster. Auto uses project settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Toggle for per-model tier variants
                    Toggle("Show service-tier variants in model list", isOn: $viewModel.openAIShowServiceTierVariants)
                        .toggleStyle(.switch)
                        .onChange(of: viewModel.openAIShowServiceTierVariants) { _, _ in
                            viewModel.saveOpenAIShowServiceTierVariants()
                            onAPIKeyUpdated?()
                        }

                    Text("Selecting a tier-variant model overrides the global tier for that request.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let selectedModel {
                if availableModels.isEmpty {
                    Text("No models available. Validate your API key first to fetch available models.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Add Custom Model")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Text("Select from available models")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Picker("", selection: selectedModel) {
                                // Add "None" option with empty string
                                Text("None (Remove custom model)").tag("")
                                Divider()

                                ForEach(availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .labelsHidden()
                            .onChange(of: selectedModel.wrappedValue) { _, _ in
                                switch title {
                                case "OpenAI API Key":
                                    viewModel.saveOpenAICustomModel()
                                case "Gemini API Key":
                                    viewModel.saveGeminiCustomModel()
                                case "DeepSeek API Key":
                                    viewModel.saveDeepSeekCustomModel()
                                case "Fireworks AI API Key":
                                    viewModel.saveFireworksCustomModel()
                                case "Grok (xAI) API Key":
                                    viewModel.saveGrokCustomModel()
                                case "Groq API Key":
                                    viewModel.saveGroqCustomModel()
                                case "Z.AI API Key":
                                    viewModel.saveZaiCustomModel()
                                default:
                                    break
                                }
                            }

                            if !selectedModel.wrappedValue.isEmpty {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                            Spacer()
                        }
                        if !selectedModel.wrappedValue.isEmpty {
                            Text("Model '\(selectedModel.wrappedValue)' added to model list")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }
            } else if let customModel {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Custom Model")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Text("Enter a compatible model name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        TextField("Enter model name", text: customModel)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Button(action: {
                            switch title {
                            case "Anthropic API Key":
                                viewModel.saveAnthropicCustomModel()
                            case "OpenAI API Key":
                                viewModel.saveOpenAICustomModel()
                            case "DeepSeek API Key":
                                viewModel.saveDeepSeekCustomModel()
                            case "Fireworks AI API Key":
                                viewModel.saveFireworksCustomModel()
                            case "Grok (xAI) API Key":
                                viewModel.saveGrokCustomModel()
                            case "Groq API Key":
                                viewModel.saveGroqCustomModel()
                            case "Z.AI API Key":
                                viewModel.saveZaiCustomModel()
                            case "Gemini API Key":
                                viewModel.saveGeminiCustomModel()
                            default:
                                break
                            }
                        }) {
                            Image(systemName: "tray.and.arrow.down")
                                .frame(width: 16, height: 16)
                        }
                        .disabled(customModel.wrappedValue.isEmpty)
                        .buttonStyle(CustomButtonStyle())

                        Button(action: {
                            // Clear the custom model field and persist the change
                            customModel.wrappedValue = ""
                            switch title {
                            case "Anthropic API Key":
                                viewModel.saveAnthropicCustomModel()
                            case "OpenAI API Key":
                                viewModel.saveOpenAICustomModel()
                            case "DeepSeek API Key":
                                viewModel.saveDeepSeekCustomModel()
                            case "Fireworks AI API Key":
                                viewModel.saveFireworksCustomModel()
                            case "Grok (xAI) API Key":
                                viewModel.saveGrokCustomModel()
                            case "Groq API Key":
                                viewModel.saveGroqCustomModel()
                            case "Z.AI API Key":
                                viewModel.saveZaiCustomModel()
                            case "Gemini API Key":
                                viewModel.saveGeminiCustomModel()
                            default:
                                break
                            }
                        }) {
                            Image(systemName: "trash")
                                .frame(width: 16, height: 16)
                        }
                        .disabled(customModel.wrappedValue.isEmpty)
                        .buttonStyle(CustomButtonStyle())
                    }

                    if !customModel.wrappedValue.isEmpty {
                        Text("Model will be added when clicking 'Save Model'")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var azureSettingsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Azure OpenAI")
                    .font(.headline)
                Button(action: {
                    openURL("https://portal.azure.com/")
                }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Base URL")
                        .frame(width: 120, alignment: .leading)
                    TextField("https://example.openai.azure.com", text: $viewModel.azureBaseURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                HStack {
                    Text("API Version")
                        .frame(width: 120, alignment: .leading)
                    TextField("API Version", text: $viewModel.azureApiVersion)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                HStack {
                    Text("API Key")
                        .frame(width: 120, alignment: .leading)
                    SecureField("Azure API Key", text: $viewModel.azureApiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }

            if isLoadingAzure {
                ProgressView()
                    .scaleEffect(0.8)
            } else if viewModel.isAzureKeyValid {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Valid Azure Key")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            if viewModel.isAzureKeyValid {
                azureCustomModelPicker()
            }

            HStack(spacing: 10) {
                Button(action: validateAndSaveAzureKey) {
                    Text(viewModel.isAzureKeyValid ? "Change" : "Validate & Save")
                        .frame(maxWidth: .infinity)
                }
                .disabled(
                    viewModel.azureBaseURL.isEmpty
                        || viewModel.azureApiKey.isEmpty
                        || viewModel.azureApiVersion.isEmpty
                        || isLoadingAzure
                )
                .buttonStyle(CustomButtonStyle())

                Button(action: deleteAzureKey) {
                    Text("Delete")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!viewModel.isAzureKeyValid || isLoadingAzure)
                .buttonStyle(CustomButtonStyle())
            }
        }
    }

    private var ollamaURLView: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Local Model Settings").font(.headline)
                    Button(action: {
                        openURL("https://ollama.com/download")
                    }) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Text("Ollama uses port 11434 | LM Studio uses port 1234")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("URL").font(.subheadline)
                HStack {
                    TextField("Enter URL", text: $viewModel.ollamaURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    if isLoadingOllama {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(height: 20)
                    } else if viewModel.isOllamaURLValid {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model").font(.subheadline)
                if viewModel.availableLocalModels.isEmpty {
                    Text("No models available. Validate URL first.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Select a model from the list to use as your local model").font(.caption).foregroundColor(.secondary)
                    HStack {
                        Picker("", selection: $viewModel.ollamaModel) {
                            ForEach(viewModel.availableLocalModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .onChange(of: viewModel.ollamaModel) { _, _ in
                            Task {
                                await viewModel.updateAvailableModels()
                            }
                        }

                        if viewModel.isOllamaModelValid {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        Spacer()
                    }
                }
            }

            HStack(spacing: 10) {
                Button(action: validateAndSaveOllamaSettings) {
                    Text(viewModel.isOllamaModelValid ? "Refresh models" : "Validate & fetch models")
                        .frame(maxWidth: .infinity)
                }
                .disabled(
                    viewModel.ollamaURL.isEmpty ||
                        isLoadingOllama
                )
                .buttonStyle(CustomButtonStyle())

                Button(action: resetOllamaSettings) {
                    Text("Reset to Default")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CustomButtonStyle())
            }
        }
    }

    private func validateAndSaveOllamaSettings() {
        isLoadingOllama = true
        Task {
            do {
                let isURLValid = try await viewModel.validateOllamaURL()
                if isURLValid {
                    let isSaved = try await viewModel.validateAndSaveKey(
                        key: viewModel.ollamaURL,
                        for: .ollama
                    ) {
                        true
                    }
                    if isSaved {
                        viewModel.updateOllamaModel(viewModel.ollamaModel)
                        await MainActor.run {
                            alertMessage = "Ollama settings and model saved successfully"
                            showAlert = true
                        }
                    } else {
                        await MainActor.run {
                            alertMessage = "Failed to save Ollama URL. Please try again."
                            showAlert = true
                        }
                    }
                } else {
                    await MainActor.run {
                        alertMessage = "Invalid Ollama URL. Please check and try again."
                        showAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    alertMessage = "Error validating Ollama settings: \(error.asFriendlyString())"
                    showAlert = true
                }
            }
            await MainActor.run {
                isLoadingOllama = false
            }
        }
    }

    private func resetOllamaSettings() {
        viewModel.ollamaURL = "http://localhost:11434"
        viewModel.ollamaModel = ""
        viewModel.availableLocalModels = []
        UserDefaults.standard.set([], forKey: "OllamaLocalModels")
        Task {
            await viewModel.updateAvailableModels()
        }
    }

    private func validateAndSaveAnthropicKey() {
        isLoadingAnthropic = true
        validateAndSaveKey(key: viewModel.anthropicApiKey, for: .anthropic) {
            try await viewModel.validateAnthropicKey()
        }
    }

    private func validateAndSaveOpenAIKey() {
        isLoadingOpenAI = true
        validateAndSaveKey(key: viewModel.openAIApiKey, for: .openAI) {
            try await viewModel.validateOpenAIKey()
        }
    }

    private func validateAndSaveGeminiKey() {
        isLoadingGemini = true
        validateAndSaveKey(key: viewModel.geminiApiKey, for: .gemini) {
            try await viewModel.validateGeminiKey()
        }
    }

    private func validateAndSaveDeepSeekKey() {
        isLoadingDeepSeek = true
        validateAndSaveKey(key: viewModel.deepSeekApiKey, for: .deepseek) {
            try await viewModel.validateDeepSeekKey()
        }
    }

    private func validateAndSaveFireworksKey() {
        isLoadingFireworks = true
        validateAndSaveKey(key: viewModel.fireworksApiKey, for: .fireworks) {
            try await viewModel.validateFireworksKey()
        }
    }

    private func validateAndSaveGrokKey() {
        isLoadingGrok = true
        validateAndSaveKey(key: viewModel.grokApiKey, for: .grok) {
            try await viewModel.validateGrokKey()
        }
    }

    private func validateAndSaveKey(
        key: String,
        for providerType: AIProviderType,
        validationFunc: @escaping () async throws -> Bool
    ) {
        Task {
            do {
                let isValid = try await viewModel.validateAndSaveKey(
                    key: key,
                    for: providerType,
                    validationFunc: validationFunc
                )
                await MainActor.run {
                    if isValid {
                        onAPIKeyUpdated?()
                    } else {
                        alertMessage = "Unable to validate API Key. Please check that your key is correct and that you have funds available in your account."
                        showAlert = true
                    }
                    isLoadingAnthropic = false
                    isLoadingOpenAI = false
                    isLoadingGemini = false
                    isLoadingDeepSeek = false
                    isLoadingFireworks = false
                    isLoadingGrok = false
                    isLoadingGroq = false
                    isLoadingZAI = false
                }
            } catch {
                await MainActor.run {
                    alertMessage = "Error validating API Key: \(error.asFriendlyString())"
                    showAlert = true
                    isLoadingAnthropic = false
                    isLoadingOpenAI = false
                    isLoadingGemini = false
                    isLoadingDeepSeek = false
                    isLoadingFireworks = false
                    isLoadingGrok = false
                    isLoadingGroq = false
                }
                isLoadingZAI = false
            }
        }
    }

    private func deleteAnthropicKey() {
        deleteKey(for: .anthropic)
    }

    private func deleteOpenAIKey() {
        deleteKey(for: .openAI)
    }

    private func deleteGeminiKey() {
        deleteKey(for: .gemini)
    }

    private func deleteDeepSeekKey() {
        deleteKey(for: .deepseek)
    }

    private func deleteFireworksKey() {
        deleteKey(for: .fireworks)
    }

    private func deleteGrokKey() {
        deleteKey(for: .grok)
    }

    private func validateAndSaveGroqKey() {
        isLoadingGroq = true
        validateAndSaveKey(key: viewModel.groqApiKey, for: .groq) {
            try await viewModel.validateGroqKey()
        }
    }

    private func deleteGroqKey() {
        deleteKey(for: .groq)
    }

    private func validateAndSaveZAIKey() {
        isLoadingZAI = true
        validateAndSaveKey(key: viewModel.zaiApiKey, for: .zAI) {
            try await viewModel.validateZAIKey()
        }
    }

    private func deleteZAIKey() {
        deleteKey(for: .zAI)
    }

    private func validateAndSaveAzureKey() {
        isLoadingAzure = true
        Task {
            do {
                let success = try await viewModel.validateAzureSettings()
                await MainActor.run {
                    isLoadingAzure = false
                    alertMessage = success ? "Azure settings validated and saved!" : "Failed to validate Azure settings."
                    showAlert = true
                    onAPIKeyUpdated?()
                }
            } catch {
                await MainActor.run {
                    isLoadingAzure = false
                    alertMessage = "Error validating Azure settings: \(error.asFriendlyString())"
                    showAlert = true
                }
            }
        }
    }

    private func deleteAzureKey() {
        isLoadingAzure = true
        Task {
            do {
                try await viewModel.deleteAzureKey()
                await MainActor.run {
                    isLoadingAzure = false
                    alertMessage = "Azure configuration removed."
                    showAlert = true
                    onAPIKeyUpdated?()
                }
            } catch {
                await MainActor.run {
                    isLoadingAzure = false
                    alertMessage = "Error deleting Azure key: \(error.asFriendlyString())"
                    showAlert = true
                }
            }
        }
    }

    private func deleteKey(for providerType: AIProviderType) {
        isLoading = true
        Task {
            do {
                try await viewModel.deleteKey(for: providerType)
                await MainActor.run {
                    alertMessage = "Key deleted successfully"
                    onAPIKeyUpdated?()
                    showAlert = true
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    alertMessage = "Error deleting key: \(error.asFriendlyString())"
                    showAlert = true
                    isLoading = false
                }
            }
        }
    }
}
