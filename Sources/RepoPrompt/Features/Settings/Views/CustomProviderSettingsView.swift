import SwiftUI

struct CustomProviderSettingsView: View {
    @ObservedObject var viewModel: APISettingsViewModel

    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var searchText = ""
    /// Shows a spinner while "Validate & Save" is running
    @State private var isValidating = false

    private var filteredModels: [String] {
        let models = viewModel.availableCustomModels
        let searchKey = searchText.lowercased()
        let indexedModels = models.map { model in
            (model: model, key: model.lowercased())
        }
        let sortedModels = indexedModels.sorted { model1, model2 in
            // First sort by enabled status
            if viewModel.isCustomModelEnabled(model1.model) != viewModel.isCustomModelEnabled(model2.model) {
                return viewModel.isCustomModelEnabled(model1.model)
            }
            // Then sort alphabetically within each group
            if model1.key != model2.key {
                return model1.key < model2.key
            }
            return model1.model < model2.model
        }

        if searchKey.isEmpty {
            return Array(sortedModels.prefix(20).map(\.model))
        }
        return sortedModels
            .filter { $0.key.contains(searchKey) }
            .prefix(20)
            .map(\.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("OpenAI-Compatible Provider Configuration")
                    .font(.headline)
                Spacer()
                Group {
                    if isValidating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else if viewModel.isCustomProviderValid {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                .frame(width: 24, height: 24, alignment: .center) // Fixed width for status icon
            }

            Text("Configure a custom provider with an OpenAI-compatible API. Enter the **Provider URL** (e.g., `https://api.yourprovider.com/v1`).\n\nIf model listing is supported, models will appear after validation. Otherwise, specify a **Preferred Model ID**.").font(.caption)

            TextField("Provider URL", text: $viewModel.customProviderURL)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            ProviderHTTPConsentView(endpoint: viewModel.customProviderConsentURL, consentEndpoint: Binding(
                get: { viewModel.customProviderHTTPConsentEndpoint },
                set: { endpoint in
                    do { try viewModel.setCustomProviderHTTPConsent(endpoint) }
                    catch {
                        alertMessage = "Could not update HTTP consent: \(error.localizedDescription)"
                        showAlert = true
                    }
                }
            ))
            .disabled(isValidating)

            SecureField("API Key", text: $viewModel.customProviderApiKey)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            TextField("Optional: Preferred Model ID (leave blank to auto-detect)", text: $viewModel.customProviderUserModel)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            Text("Enter a model ID to use directly, or leave blank to auto-detect from the provider.").font(.caption).foregroundColor(.secondary)

            HStack {
                Text("Default Output Max Tokens:")
                TextField("e.g., 8192", text: $viewModel.customProviderMaxTokensString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: 100)
                Button(action: {
                    Task {
                        do {
                            try await viewModel.saveCustomProviderMaxTokens()
                            alertMessage = "Maximum token limit updated."
                        } catch {
                            alertMessage = "Failed to save max tokens: \(error.localizedDescription)"
                        }
                        showAlert = true
                    }
                }) {
                    Image(systemName: "tray.and.arrow.down")
                        .frame(width: 16, height: 16)
                }
                .disabled(!viewModel.isCustomProviderValid || isValidating)
                .buttonStyle(CustomButtonStyle())
            }
            Text("Set to 0 for model default. Increase if outputs are cut off.").font(.caption).foregroundColor(.secondary)

            HStack {
                Button("Validate & Save") {
                    isValidating = true
                    Task {
                        defer { isValidating = false }
                        do {
                            let ok = try await viewModel.validateCustomProvider()
                            if ok {
                                viewModel.isCustomProviderValid = true
                                alertMessage = "Custom provider configured successfully"
                            }
                        } catch {
                            alertMessage = "Error validating custom provider: \(error.localizedDescription)"
                        }
                        showAlert = true
                    }
                }
                .disabled(isValidating)
                .buttonStyle(CustomButtonStyle())

                Button("Delete Provider") {
                    Task {
                        try? await viewModel.deleteCustomProvider()
                        alertMessage = "Custom provider deleted"
                        showAlert = true
                    }
                }
                .disabled(!viewModel.isCustomProviderValid || isValidating)
                .buttonStyle(CustomButtonStyle())

                Spacer()

                HStack(spacing: 4) {
                    Text("Content-Type header")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Toggle("", isOn: $viewModel.customProviderIncludeContentType)
                        .toggleStyle(SwitchToggleStyle())
                        .scaleEffect(0.8)
                }
            }

            if viewModel.isCustomProviderValid {
                modelListSection
            } else {
                Spacer()
            }
        }
        .padding(.horizontal)
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Custom Provider"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }

    private var modelListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Available Models").font(.headline)
            Text("Models reported by your provider. Enable the models you want to use.").font(.caption)

            TextField("Search models...", text: $searchText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding(.bottom, 8)

            if viewModel.availableCustomModels.isEmpty {
                Text("No models available")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredModels, id: \.self) { model in
                            modelRow(model)
                        }

                        if !searchText.isEmpty, viewModel.availableCustomModels.count > 20 {
                            Text("Showing first 20").font(.caption).foregroundColor(.secondary).padding(.vertical, 8)
                        } else if searchText.isEmpty, viewModel.availableCustomModels.count > 20 {
                            Text("Showing first 20").font(.caption).foregroundColor(.secondary).padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private func modelRow(_ model: String) -> some View {
        HStack {
            Button(action: {
                viewModel.toggleCustomModel(model)
            }) {
                Image(systemName: viewModel.isCustomModelEnabled(model) ? "minus.circle.fill" : "plus.circle")
                    .foregroundColor(viewModel.isCustomModelEnabled(model) ? .red : .blue)
            }
            .buttonStyle(PlainButtonStyle())

            Text(model)

            if viewModel.isCustomModelEnabled(model) {
                Text("Enabled")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
    }
}
