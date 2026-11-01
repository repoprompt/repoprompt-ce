import SwiftUI

struct OpenRouterSettingsView: View {
    @ObservedObject var viewModel: APISettingsViewModel

    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var newHeaderKey = ""
    @State private var newHeaderValue = ""
    @State private var showAdvancedSettings = false

    var body: some View {
        ScrollView {
            settingsContent
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("OpenRouter Settings"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            Divider()
                .padding(.horizontal, -16)

            openRouterApiSection

            if viewModel.isOpenRouterKeyValid {
                Divider()
                    .padding(.horizontal, -16)

                // Advanced settings with custom implementation where entire header is clickable
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: {
                        withAnimation {
                            showAdvancedSettings.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: showAdvancedSettings ? "chevron.down" : "chevron.right")

                            Text("Advanced Configuration")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())

                    if showAdvancedSettings {
                        VStack(alignment: .leading, spacing: 12) {
                            providerConfigSection

                            Divider()
                                .padding(.horizontal, -16)

                            customHeadersSection

                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }

            if !showAdvancedSettings {
                Divider()
                    .padding(.horizontal, -16)
                openRouterFetchedModelsSection
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Subviews

extension OpenRouterSettingsView {
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("OpenRouter Configuration")
                    .font(.headline)
                if viewModel.isOpenRouterKeyValid {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            Text("Use your OpenRouter key to fetch a list of available models.\nPick or remove which ones you want to appear in your final list.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var openRouterApiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter API Key").font(.subheadline)
            SecureField("Enter your OpenRouter API key", text: $viewModel.openRouterApiKey)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack(spacing: 10) {
                Button(action: validateAndFetchOpenRouterKey) {
                    Text(viewModel.isOpenRouterKeyValid ? "Change Key & Refresh" : "Validate & Fetch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(viewModel.openRouterApiKey.isEmpty)

                Button(action: deleteOpenRouterKey) {
                    Text("Delete Key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CustomButtonStyle())
                .disabled(!viewModel.isOpenRouterKeyValid)
            }
        }
    }

    private var providerConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider Settings").font(.subheadline)

            Toggle("Include default OpenRouter models", isOn: $viewModel.includeDefaultOpenRouterModels)
                .onChange(of: viewModel.includeDefaultOpenRouterModels) { _, _ in
                    Task {
                        await viewModel.updateAvailableModels()
                    }
                }
                .padding(.bottom, 4)

            Toggle("Use Custom Settings", isOn: Binding(
                get: { viewModel.openRouterConfig.useCustomSettings },
                set: { viewModel.updateOpenRouterConfig(useCustomSettings: $0) }
            ))
            .padding(.bottom, 4)

            if viewModel.openRouterConfig.useCustomSettings {
                // More compact max tokens settings
                HStack {
                    Text("Max Tokens:")
                    Spacer()
                    TextField("Default", value: Binding(
                        get: { viewModel.openRouterConfig.baseConfig.maxTokens ?? 8192 },
                        set: { viewModel.updateOpenRouterConfig(maxTokens: $0) }
                    ), formatter: NumberFormatter())
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)

                    Button(action: {
                        viewModel.updateOpenRouterConfig(maxTokens: 8192)
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private var customHeadersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Custom Headers").font(.subheadline)
                Spacer()
                Text("(You can add multiple headers)").font(.caption).foregroundColor(.secondary)
            }

            // Display existing headers in a more compact format
            if viewModel.openRouterConfig.customHeaders.isEmpty {
                Text("No custom headers added yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(viewModel.openRouterConfig.customHeaders.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key).font(.caption)
                        Spacer()
                        Text(viewModel.openRouterConfig.customHeaders[key] ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(action: {
                            viewModel.removeOpenRouterHeader(key: key)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                                .imageScale(.small)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 1)
                }
            }

            Divider().padding(.vertical, 4)

            // Add new header UI - more compact
            Text("Add New Header").font(.caption).bold()
            HStack {
                TextField("Header Name", text: $newHeaderKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                TextField("Value", text: $newHeaderValue)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button(action: addCustomHeader) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(newHeaderKey.isEmpty)
            }
            // .font(.caption)
        }
    }

    private var openRouterFetchedModelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 1) Custom-added models at top
            Text("Registered Models").font(.caption).fontWeight(.semibold)

            LazyVStack(alignment: .leading) {
                ForEach(viewModel.customOpenRouterModels, id: \.self) { model in
                    HStack {
                        Text("\(model)")
                        Spacer()
                        Button(action: {
                            removeCustomOpenRouterModel(model)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.trailing, 20)

            Divider()

            Text("Available Models (from OpenRouter)")
                .font(.subheadline)
                .padding(.top, 8)

            // 2) Search field
            HStack {
                TextField("Search fetched models...", text: $viewModel.openRouterModelsSearchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button(action: {
                    Task {
                        await viewModel.fetchOpenRouterModels()
                    }
                }) {
                    Text("Refresh Model List")
                }
                .buttonStyle(CustomButtonStyle())
            }

            // 3) Fetched model listing
            if viewModel.isFetchingOpenRouterModels {
                ProgressView("Fetching models...")
                    .padding(.vertical, 4)
            } else {
                let filtered = fetchedModelsFiltered
                if filtered.isEmpty {
                    Text("No matching models found in the fetched list.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                    Spacer()
                } else {
                    LazyVStack(alignment: .leading) {
                        ForEach(filtered.prefix(20), id: \.self) { model in
                            modelRow(model)
                        }
                        if filtered.count > 20 {
                            Text("Showing first 20 models")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.trailing, 20)
                }
            }
        }
    }

    private func modelRow(_ model: String) -> some View {
        HStack {
            Button(action: {
                toggleCustomModel(model)
            }) {
                if viewModel.customOpenRouterModels.contains(model) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.blue)
                }
            }
            .buttonStyle(PlainButtonStyle())
            Text("\(model)")
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Computed

extension OpenRouterSettingsView {
    private var fetchedModelsFiltered: [String] {
        let search = viewModel.openRouterModelsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if search.isEmpty {
            return viewModel.fetchedOpenRouterModels
        }
        return viewModel.fetchedOpenRouterModels.filter { $0.lowercased().contains(search) }
    }
}

// MARK: - Button Handlers

extension OpenRouterSettingsView {
    private func addCustomHeader() {
        let key = newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            viewModel.setOpenRouterHeader(key: key, value: newHeaderValue)
            newHeaderKey = ""
            newHeaderValue = ""
        }
    }

    private func validateAndFetchOpenRouterKey() {
        Task {
            do {
                let isValid = try await viewModel.validateOpenRouterKey()
                if isValid {
                    alertMessage = "OpenRouter key validated. Models updated."
                } else {
                    alertMessage = viewModel.lastErrorMessage ?? "Invalid or unreachable key"
                }
                showAlert = true
            } catch {
                alertMessage = "Error validating OpenRouter key: \(error.localizedDescription)"
                showAlert = true
            }
        }
    }

    private func deleteOpenRouterKey() {
        Task {
            do {
                try await viewModel.deleteKey(for: .openRouter)
                alertMessage = "OpenRouter key deleted"
                showAlert = true
            } catch {
                alertMessage = "Error deleting OpenRouter key: \(error.localizedDescription)"
                showAlert = true
            }
        }
    }

    private func toggleCustomModel(_ modelName: String) {
        if viewModel.customOpenRouterModels.contains(modelName) {
            // Remove it
            if let idx = viewModel.customOpenRouterModels.firstIndex(of: modelName) {
                viewModel.removeCustomOpenRouterModel(at: idx)
            }
        } else {
            // Add new
            viewModel.customOpenRouterModels.append(modelName)
            viewModel.validOpenRouterModels.insert(modelName)
            UserDefaults.standard.set(viewModel.customOpenRouterModels, forKey: "CustomOpenRouterModels")
        }
        Task {
            await viewModel.updateAvailableModels()
        }
    }

    private func removeCustomOpenRouterModel(_ modelName: String) {
        if let idx = viewModel.customOpenRouterModels.firstIndex(of: modelName) {
            viewModel.removeCustomOpenRouterModel(at: idx)
        }
    }
}
