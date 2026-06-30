import Combine
import Foundation
import Logging
import MCP // For ServerNetworkManager.broadcastToolListChanged()
import SwiftUI

/// Shared runtime & persistence layer for per-tool enable/disable flags.
@MainActor
final class ToolAvailabilityStore: ObservableObject {
    // MARK: - Published state

    @Published private(set) var disabledTools: Set<String> // names only
    @Published private(set) var globallySuppressedTools: Set<String>
    /// NOTE: allTools is intentionally not @Published to avoid large UI invalidations
    private(set) var allTools: [Tool] = [] // full metadata

    struct ToolSummary: Identifiable, Equatable {
        var id: String {
            name
        }

        let name: String
        let description: String
    }

    @Published private(set) var toolSummaries: [ToolSummary] = []

    /// Tools that should be shown in end-user MCP settings and status surfaces.
    /// Excludes policy-gated tools that are only available in discovery/agent runs.
    var advertisedTools: [Tool] {
        allTools.filter { Self.isAdvertisedToolName($0.name) && !globallySuppressedTools.contains($0.name) }
    }

    /// Tool summaries filtered to only tools visible to normal MCP clients.
    var advertisedToolSummaries: [ToolSummary] {
        toolSummaries.filter { Self.isAdvertisedToolName($0.name) && !globallySuppressedTools.contains($0.name) }
    }

    // MARK: - Singleton

    static let shared = ToolAvailabilityStore()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        disabledTools = Set(saved)
        globallySuppressedTools = Self.suppressedToolNames(
            codeMapsGloballyDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled()
        )

        GlobalSettingsStore.shared.$codeMapsGloballyDisabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] disabled in
                Task { @MainActor in
                    self?.setGloballySuppressedTools(Self.suppressedToolNames(codeMapsGloballyDisabled: disabled))
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Broadcast Debounce

    private var broadcastWorkItem: DispatchWorkItem?
    private let broadcastWorkGate = WorkItemGate()
    private func scheduleBroadcast() {
        broadcastWorkItem?.cancel()
        broadcastWorkGate.cancel()
        broadcastWorkItem = broadcastWorkGate.schedule(on: DispatchQueue.global(qos: .utility), after: 0.2) {
            Task.detached(priority: .utility) {
                await ServerNetworkManager.shared.broadcastToolListChanged()
            }
        }
    }

    // MARK: - Public API

    /// Effective disabled set, combining persisted user toggles with transient global suppressions.
    var effectiveDisabledTools: Set<String> {
        disabledTools.union(globallySuppressedTools)
    }

    /// Returns `true` when the tool is *enabled* (not in the effective disabled set).
    func isEnabled(_ name: String) -> Bool {
        !effectiveDisabledTools.contains(name)
    }

    func globalSuppressionReason(for name: String) -> String? {
        guard globallySuppressedTools.contains(name) else { return nil }
        if name == "get_code_structure" {
            return "Code Maps are globally disabled in Advanced Settings."
        }
        return "This tool is temporarily unavailable due to global settings."
    }

    /// Toggle tool availability and persist change.
    func toggle(_ name: String, enabled: Bool) async {
        if enabled {
            disabledTools.remove(name)
        } else {
            disabledTools.insert(name)
        }
        save()

        // Notify all connected clients without blocking the main actor
        scheduleBroadcast()
    }

    /// Registers newly discovered `Tool`s so the UI can present them.
    func registerTools(_ tools: [Tool]) {
        // Evaluate default enable flags BEFORE appending to `allTools`
        applyDefaultFlags(for: tools)

        var changed = false
        for tool in tools {
            if !allTools.contains(where: { $0.name == tool.name }) {
                allTools.append(tool)
                changed = true
            }
            if !toolSummaries.contains(where: { $0.name == tool.name }) {
                toolSummaries.append(ToolSummary(name: tool.name, description: tool.description))
                changed = true
            }
        }

        if changed {
            allTools.sort { lhs, rhs in
                let lhsKey = lhs.name.lowercased()
                let rhsKey = rhs.name.lowercased()
                if lhsKey != rhsKey {
                    return lhsKey < rhsKey
                }
                return lhs.name < rhs.name
            }
            toolSummaries.sort { lhs, rhs in
                let lhsKey = lhs.name.lowercased()
                let rhsKey = rhs.name.lowercased()
                if lhsKey != rhsKey {
                    return lhsKey < rhsKey
                }
                return lhs.name < rhs.name
            }
            scheduleBroadcast()
        }
    }

    /// Removes tools that are no longer available
    func unregisterTools(_ toolNames: [String]) {
        guard !toolNames.isEmpty else { return }

        var changed = false
        let originalAllCount = allTools.count
        if originalAllCount > 0 {
            allTools.removeAll { toolNames.contains($0.name) }
            changed = changed || allTools.count != originalAllCount
        }

        let originalSummaryCount = toolSummaries.count
        if originalSummaryCount > 0 {
            toolSummaries.removeAll { toolNames.contains($0.name) }
            changed = changed || toolSummaries.count != originalSummaryCount
        }

        for name in toolNames {
            if disabledTools.remove(name) != nil {
                changed = true
            }
        }

        if changed {
            save()
            scheduleBroadcast()
        }
    }

    // MARK: - Helpers

    private func applyDefaultFlags(for tools: [Tool]) {
        var changed = false
        for t in tools {
            if !t.isEnabledByDefault, !disabledTools.contains(t.name) {
                disabledTools.insert(t.name) // first-time default OFF
                changed = true
            }
        }
        if changed { save() } // only persist when needed
    }

    private func save() {
        UserDefaults.standard.set(Array(disabledTools), forKey: Self.defaultsKey)
    }

    private static let defaultsKey = "mcp.disabledTools"

    nonisolated static func suppressedToolNames(codeMapsGloballyDisabled _: Bool) -> Set<String> {
        []
    }

    private func setGloballySuppressedTools(_ names: Set<String>) {
        guard globallySuppressedTools != names else { return }
        globallySuppressedTools = names
        scheduleBroadcast()
    }

    private static func isAdvertisedToolName(_ name: String) -> Bool {
        !MCPPolicyGatedTools.names.contains(name)
    }
}
