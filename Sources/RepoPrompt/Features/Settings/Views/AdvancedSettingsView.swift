//
//  AdvancedSettingsView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-21.
//

import SwiftUI

/// Slimmed Advanced Settings page. Controls are grouped into focused sections
/// for progressive-disclosure-friendly browsing.
///
/// SEARCH-HELPER: Advanced Settings, File System, AI Behavior, Code Maps,
/// URL Opener, URL scheme, deep links, gitignore, symlinks, saved prompts,
/// datetime instructions
///
/// Related:
/// - Keyboard Shortcuts: /RepoPrompt/Views/Settings/KeyboardShortcutsSettingsView.swift
/// - Plan:               /docs/plans/settings-ui-agent-mode-progressive-disclosure-plan-2026-04-17.md
struct AdvancedSettingsView: View {
    // MARK: - View Models

    @ObservedObject var fileManager: WorkspaceFilesViewModel
    @ObservedObject var promptViewModel: PromptViewModel
    @ObservedObject private var globalSettings = GlobalSettingsStore.shared
    let windowState: WindowState

    private var enableKeyboardShortcutsBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.enableKeyboardShortcuts() },
            set: { globalSettings.setEnableKeyboardShortcuts($0) }
        )
    }

    private var canonicalURLPrefix: String {
        "\(AppDeepLinkURLScheme.canonical)://"
    }

    private var respectGitignoreBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.respectGitignore() },
            set: { setFileSystemPreference($0, key: "file_system.respect_gitignore", store: { globalSettings.setRespectGitignore($0) }) }
        )
    }

    private var respectRepoIgnoreBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.respectRepoIgnore() },
            set: { setFileSystemPreference($0, key: "file_system.respect_repo_ignore", store: { globalSettings.setRespectRepoIgnore($0) }) }
        )
    }

    private var respectCursorignoreBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.respectCursorignore() },
            set: { setFileSystemPreference($0, key: "file_system.respect_cursorignore", store: { globalSettings.setRespectCursorignore($0) }) }
        )
    }

    private var enableHierarchicalIgnoresBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.enableHierarchicalIgnores() },
            set: { setFileSystemPreference($0, key: "file_system.enable_hierarchical_ignores", store: { globalSettings.setEnableHierarchicalIgnores($0) }) }
        )
    }

    private var skipSymlinksBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.skipSymlinks() },
            set: { setFileSystemPreference($0, key: "file_system.skip_symlinks", store: { globalSettings.setSkipSymlinks($0) }) }
        )
    }

    private var showEmptyFoldersBinding: Binding<Bool> {
        Binding(
            get: { globalSettings.showEmptyFolders() },
            set: { setFileSystemPreference($0, key: "file_system.show_empty_folders", store: { globalSettings.setShowEmptyFolders($0) }) }
        )
    }

    private func setFileSystemPreference(
        _ value: Bool,
        key: String,
        store: (Bool) -> Void
    ) {
        store(value)
        globalSettings.postFileSystemPreferencesDidChange(key: key)
    }

    init(
        fileManager: WorkspaceFilesViewModel,
        promptViewModel: PromptViewModel,
        windowState: WindowState
    ) {
        self.fileManager = fileManager
        self.promptViewModel = promptViewModel
        self.windowState = windowState
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()
                    .padding(.horizontal, -16)

                fileSystemSection

                Divider()
                    .padding(.horizontal, -16)

                aiBehaviorSection

                Divider()
                    .padding(.horizontal, -16)

                keyboardShortcutsSection

                Divider()
                    .padding(.horizontal, -16)

                urlOpenerSection

                Divider()
                    .padding(.horizontal, -16)

                savedPromptsSection

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Advanced")
                .font(.title2)
                .fontWeight(.semibold)

            Text("File system, AI behavior, URL opener, and saved-prompts utilities. Use sparingly — most daily settings live in the sections above.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - File System

    private var fileSystemSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("File System")
                .font(.title3)
                .fontWeight(.semibold)

            SettingSection(
                title: "Workspace Folder Scanning",
                description: "Changes refresh open folders and are shared with app_settings MCP writes."
            ) {
                SettingToggle(
                    title: "Respect .gitignore rules",
                    description: "Honor .gitignore files while scanning workspace folders.",
                    isOn: respectGitignoreBinding
                )

                SettingToggle(
                    title: "Respect .repo_ignore rules",
                    description: "Honor RepoPrompt-specific .repo_ignore files. Edit local .repo_ignore content through the Ignore Patterns editor or file editing tools.",
                    isOn: respectRepoIgnoreBinding
                )

                SettingToggle(
                    title: "Respect .cursorignore rules",
                    description: "Honor .cursorignore files while scanning workspace folders.",
                    isOn: respectCursorignoreBinding
                )

                SettingToggle(
                    title: "Respect nested ignore files",
                    description: "Honor ignore files found in nested directories, not just the workspace root.",
                    isOn: enableHierarchicalIgnoresBinding
                )

                SettingToggle(
                    title: "Follow symbolic links",
                    description: "Symbolic links will be followed when scanning directories.",
                    isOn: Binding(
                        get: { !globalSettings.skipSymlinks() },
                        set: { skipSymlinksBinding.wrappedValue = !$0 }
                    )
                )

                SettingToggle(
                    title: "Show empty folders",
                    description: "Display empty folders in workspace folder listings.",
                    isOn: showEmptyFoldersBinding
                )
            }
        }
    }

    // MARK: - AI Behavior

    private var aiBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Behavior")
                .font(.title3)
                .fontWeight(.semibold)

            SettingSection(
                title: "Code Maps",
                description: "Globally disable Code Map scanning and prompt inclusion without changing workspace Copy or Chat modes."
            ) {
                SettingToggle(
                    title: "Disable Code Maps globally",
                    description: "When enabled, RepoPrompt preserves your per-workspace Code Map modes but ignores them and cancels active scans.",
                    isOn: Binding(
                        get: { globalSettings.codeMapsGloballyDisabled },
                        set: { globalSettings.setCodeMapsGloballyDisabled($0) }
                    )
                )

                if globalSettings.codeMapsGloballyDisabled {
                    Text("Code Maps are disabled globally. Existing Copy and Chat Code Map modes are preserved and will take effect again when this is turned off.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
            }

            SettingSection(
                title: "Prompt Packaging",
                description: "Affects how RepoPrompt assembles copied prompts and built-in chat instructions."
            ) {
                Picker("File path display", selection: $promptViewModel.filePathDisplayOption) {
                    ForEach(FilePathDisplay.allCases, id: \.self) { mode in
                        Text(mode.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .labelsHidden()
                .frame(width: 300, alignment: .leading)

                SettingToggle(
                    title: "Include datetime in user instructions",
                    description: "Add a timestamp attribute to user instruction tags when packaging prompts.",
                    isOn: $promptViewModel.includeDatetimeInUserInstructions
                )
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private var keyboardShortcutsSection: some View {
        SettingSection(
            title: "Keyboard Shortcuts",
            description: "Turn global hotkeys on or off. Use the dedicated Keyboard Shortcuts tab to view and remap every binding."
        ) {
            SettingToggle(
                title: "Enable keyboard shortcuts",
                description: "When disabled, all global shortcuts are inactive (custom bindings are preserved in Keyboard Shortcuts).",
                isOn: enableKeyboardShortcutsBinding
            )

            Button("Open Keyboard Shortcuts…") {
                NotificationCenter.default.post(
                    name: .showKeyboardShortcutsSettingsTab,
                    object: nil,
                    userInfo: ["windowID": windowState.windowID]
                )
            }
            .buttonStyle(CustomButtonStyle())
            .hoverTooltip("Opens the Keyboard Shortcuts settings tab for this window.")
        }
    }

    // MARK: - URL Opener

    private var urlOpenerSection: some View {
        SettingSection(
            title: "URL Opener",
            description: "Use RepoPrompt CE links to open folders, select files, seed prompt text, and focus windows from external tools."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Canonical scheme: \(AppDeepLinkURLScheme.canonical)://")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                VStack(alignment: .leading, spacing: 8) {
                    urlExampleRow(
                        title: "Open a folder",
                        value: "\(canonicalURLPrefix)open//Users/example/Project"
                    )
                    urlExampleRow(
                        title: "Select files and prompt text",
                        value: "\(canonicalURLPrefix)open//Users/example/Project?files=Sources/App.swift,README.md&prompt=Review%20the%20selected%20files"
                    )
                    urlExampleRow(
                        title: "Focus or create an ephemeral workspace",
                        value: "\(canonicalURLPrefix)open//Users/example/Project?workspace=Review&focus=true&ephemeral=true"
                    )
                    urlExampleRow(
                        title: "Create a saved prompt",
                        value: "\(canonicalURLPrefix)prompt?title=Review&content=Review%20the%20current%20selection&focus=true"
                    )
                }

                Text("Supported opener parameters: workspace, files, prompt, focus, ephemeral, and persist. Use \(canonicalURLPrefix) for external links.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func urlExampleRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 8) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .buttonStyle(CustomButtonStyle())
                .hoverTooltip("Copy this URL example.")
            }
        }
    }

    // MARK: - Saved Prompts

    private var savedPromptsSection: some View {
        SettingSection(
            title: "Saved Prompts",
            description: "Manage your saved instruction prompts. Reset to defaults if you're experiencing issues."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button("Export Prompts") {
                        let savePanel = NSSavePanel()
                        savePanel.title = "Export Saved Prompts"
                        savePanel.prompt = "Export"
                        savePanel.nameFieldStringValue = "SavedPrompts.json"

                        if savePanel.runModal() == .OK, let url = savePanel.url {
                            do {
                                try promptViewModel.exportPrompts(to: url)
                            } catch {
                                let alert = NSAlert()
                                alert.messageText = "Export Failed"
                                alert.informativeText = error.localizedDescription
                                alert.alertStyle = .warning
                                alert.runModal()
                            }
                        }
                    }
                    .buttonStyle(CustomButtonStyle())
                    .frame(minWidth: 120)

                    Button("Import Prompts") {
                        let openPanel = NSOpenPanel()
                        openPanel.title = "Import Saved Prompts"
                        openPanel.prompt = "Import"
                        openPanel.allowedFileTypes = ["json"]
                        openPanel.canChooseFiles = true
                        openPanel.canChooseDirectories = false

                        if openPanel.runModal() == .OK, let url = openPanel.url {
                            do {
                                let addedCount = try promptViewModel.importPrompts(from: url)
                                let alert = NSAlert()
                                alert.messageText = "Import Complete"
                                alert.informativeText = "Successfully added \(addedCount) new prompt(s)."
                                alert.runModal()
                            } catch {
                                let alert = NSAlert()
                                alert.messageText = "Import Failed"
                                alert.informativeText = error.localizedDescription
                                alert.alertStyle = .warning
                                alert.runModal()
                            }
                        }
                    }
                    .buttonStyle(CustomButtonStyle())
                    .frame(minWidth: 120)

                    Button("Reset Prompts") {
                        let alert = NSAlert()
                        alert.messageText = "Reset Saved Prompts"
                        alert.informativeText = "This will remove all custom prompts and restore the default prompts. This action cannot be undone."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Reset")
                        alert.addButton(withTitle: "Cancel")

                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            promptViewModel.resetUserPrompts()
                        }
                    }
                    .buttonStyle(CustomButtonStyle())
                    .hoverTooltip("Clears all user-defined prompts and restores the default built-in prompts.")
                    .frame(minWidth: 120)
                }
            }
        }
    }
}
