import Combine
import Foundation
import SwiftUI

// MARK: - Agent Workflow Store

/// Manages custom agent workflows stored as markdown files in Application Support.
/// Watches the Workflows directory for changes and provides create/clone helpers.
///
/// Related:
/// - Model: `AgentWorkflowDefinition` in `Models/Agent/AgentWorkflow.swift`
/// - Directory watcher pattern: `MCPExternalEventsMonitor`
/// - Storage conventions: `MCPFilesystemConstants`
@MainActor
final class AgentWorkflowStore: ObservableObject {
    static let shared = AgentWorkflowStore()

    // MARK: Published state

    @Published private(set) var customWorkflows: [AgentWorkflowDefinition] = []

    /// Maps custom workflow UUID to its file URL on disk.
    private var fileURLsByID: [UUID: URL] = [:]

    /// Raw values of built-in workflows the user has hidden.
    @Published var hiddenBuiltInIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hiddenBuiltInIDs), forKey: Self.hiddenBuiltInKey)
        }
    }

    @Published private(set) var featuredWorkflowIDs: [String]

    private static let hiddenBuiltInKey = "AgentWorkflowStore.hiddenBuiltInIDs"
    static let defaultHiddenBuiltInIDs: Set<String> = [AgentWorkflow.build.rawValue]
    private static let featuredWorkflowIDsKey = "AgentWorkflowStore.featuredWorkflowIDs"
    private static let featuredDefaultsVersionKey = "AgentWorkflowStore.featuredDefaultsVersion"
    static let maxFeaturedWorkflowCount = 4

    /// Bump this version whenever `defaultFeaturedWorkflowIDs` changes.
    /// On launch, if the persisted version is older, the defaults are re-applied.
    private static let featuredDefaultsVersion = 3
    private static let defaultFeaturedWorkflowIDs = [
        AgentWorkflow.orchestrate.definition.id,
        AgentWorkflow.review.definition.id,
        AgentWorkflow.deepPlan.definition.id,
        AgentWorkflow.oracleExport.definition.id
    ]

    /// Visible built-in workflows (excludes hidden ones).
    var visibleBuiltInWorkflows: [AgentWorkflowDefinition] {
        AgentWorkflow.builtInSections(hiddenBuiltInIDs: hiddenBuiltInIDs).visibleBuiltIns
    }

    /// All built-in workflows, regardless of hidden state.
    var builtInWorkflows: [AgentWorkflowDefinition] {
        AgentWorkflow.displayOrder.map(\.definition)
    }

    /// All workflows: visible built-in + custom.
    var allWorkflows: [AgentWorkflowDefinition] {
        visibleBuiltInWorkflows + customWorkflows
    }

    /// All workflows that can appear on the main agent empty state.
    var featureableWorkflows: [AgentWorkflowDefinition] {
        builtInWorkflows + customWorkflows
    }

    var featuredWorkflows: [AgentWorkflowDefinition] {
        featuredWorkflowIDs.compactMap(resolveWorkflow)
    }

    func isBuiltInHidden(_ workflow: AgentWorkflow) -> Bool {
        hiddenBuiltInIDs.contains(workflow.rawValue)
    }

    func setBuiltInVisibility(_ workflow: AgentWorkflow, isVisible: Bool) {
        let isHidden = hiddenBuiltInIDs.contains(workflow.rawValue)
        guard isVisible == isHidden else { return }

        if isVisible {
            hiddenBuiltInIDs.remove(workflow.rawValue)
        } else {
            hiddenBuiltInIDs.insert(workflow.rawValue)
            removeFeaturedWorkflow(withID: workflow.definition.id)
        }
    }

    func toggleBuiltInVisibility(_ workflow: AgentWorkflow) {
        setBuiltInVisibility(workflow, isVisible: hiddenBuiltInIDs.contains(workflow.rawValue))
    }

    func isFeatured(_ workflow: AgentWorkflowDefinition) -> Bool {
        featuredWorkflowIDs.contains(workflow.id)
    }

    func canFeature(_ workflow: AgentWorkflowDefinition) -> Bool {
        if isFeatured(workflow) { return true }
        guard !isHiddenBuiltIn(workflow) else { return false }
        return featuredWorkflowIDs.count < Self.maxFeaturedWorkflowCount
    }

    func toggleFeatured(_ workflow: AgentWorkflowDefinition) {
        if isFeatured(workflow) {
            removeFeaturedWorkflow(withID: workflow.id)
        } else {
            guard canFeature(workflow) else { return }
            updateFeaturedWorkflowIDs(featuredWorkflowIDs + [workflow.id])
        }
    }

    func removeFeaturedWorkflow(withID workflowID: String) {
        updateFeaturedWorkflowIDs(featuredWorkflowIDs.filter { $0 != workflowID })
    }

    func moveFeaturedWorkflow(withID workflowID: String, direction: Int) {
        guard let currentIndex = featuredWorkflowIDs.firstIndex(of: workflowID) else { return }
        let newIndex = currentIndex + direction
        guard featuredWorkflowIDs.indices.contains(newIndex) else { return }
        var updated = featuredWorkflowIDs
        let workflowID = updated.remove(at: currentIndex)
        updated.insert(workflowID, at: newIndex)
        updateFeaturedWorkflowIDs(updated)
    }

    // MARK: Filesystem paths

    /// `~/Library/Application Support/RepoPrompt CE/Workflows/`
    static var workflowsDirectoryURL: URL {
        MCPFilesystemConstants.identity.applicationSupportRootURL()
            .appendingPathComponent("Workflows", isDirectory: true)
    }

    @discardableResult
    static func ensureWorkflowsDirectoryExists() throws -> URL {
        let url = workflowsDirectoryURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    // MARK: Init

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.hiddenBuiltInKey) {
            hiddenBuiltInIDs = Set(saved)
        } else {
            hiddenBuiltInIDs = Self.defaultHiddenBuiltInIDs
        }
        featuredWorkflowIDs = UserDefaults.standard.stringArray(forKey: Self.featuredWorkflowIDsKey)
            ?? Self.defaultFeaturedWorkflowIDs

        let persistedVersion = UserDefaults.standard.integer(forKey: Self.featuredDefaultsVersionKey)
        if persistedVersion < Self.featuredDefaultsVersion {
            featuredWorkflowIDs = Self.defaultFeaturedWorkflowIDs
            persistFeaturedWorkflowIDs()
            UserDefaults.standard.set(Self.featuredDefaultsVersion, forKey: Self.featuredDefaultsVersionKey)
        }

        refresh()
    }

    // MARK: Loading

    func refresh() {
        let dir = Self.workflowsDirectoryURL
        let fm = FileManager.default

        guard fm.fileExists(atPath: dir.path) else {
            customWorkflows = []
            fileURLsByID = [:]
            syncFeaturedWorkflowsWithCurrentCatalog()
            return
        }

        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var workflows: [AgentWorkflowDefinition] = []
            var urlMap: [UUID: URL] = [:]
            for fileURL in files {
                if let workflow = parseWorkflowFile(at: fileURL), let id = workflow.customID {
                    workflows.append(workflow)
                    urlMap[id] = fileURL
                }
            }
            customWorkflows = workflows
            fileURLsByID = urlMap
            syncFeaturedWorkflowsWithCurrentCatalog()
        } catch {
            print("[AgentWorkflowStore] Failed to list Workflows directory: \(error)")
            return
        }
    }

    // MARK: Parsing

    /// Parses a markdown workflow file with optional YAML frontmatter.
    ///
    /// Frontmatter keys: `id`, `name`, `icon`, `accent_color`, `tooltip`, `description`
    /// If no `id` in frontmatter, derives UUID from filename pattern `workflow-<uuid>.md`.
    private func parseWorkflowFile(at url: URL) -> AgentWorkflowDefinition? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var frontmatter: [String: String] = [:]
        var templateBody = content

        // Parse frontmatter
        if content.hasPrefix("---") {
            let searchRange = content.index(content.startIndex, offsetBy: 3) ..< content.endIndex
            if let closingRange = content.range(of: "\n---", range: searchRange) {
                let fmText = String(content[content.index(content.startIndex, offsetBy: 3) ..< closingRange.lowerBound])
                templateBody = String(content[closingRange.upperBound...]).trimmingCharacters(in: .newlines)

                for line in fmText.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
                    let key = String(trimmed[trimmed.startIndex ..< colonIndex]).trimmingCharacters(in: .whitespaces)
                    var value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    // Strip surrounding quotes
                    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    frontmatter[key] = value
                }
            }
        }

        // Determine ID
        let workflowID: UUID
        if let idStr = frontmatter["id"], let parsed = UUID(uuidString: idStr) {
            workflowID = parsed
        } else {
            // Try filename pattern: workflow-<uuid>.md
            let stem = url.deletingPathExtension().lastPathComponent
            if stem.hasPrefix("workflow-"), let parsed = UUID(uuidString: String(stem.dropFirst("workflow-".count))) {
                workflowID = parsed
            } else {
                // Generate deterministic UUID from filename
                workflowID = UUID(uuidString: deterministicUUID(from: url.lastPathComponent)) ?? UUID()
            }
        }

        let name = frontmatter["name"] ?? url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized

        return AgentWorkflowDefinition(
            customID: workflowID,
            displayName: name,
            iconName: frontmatter["icon"] ?? "gearshape.fill",
            accentColorHex: frontmatter["accent_color"],
            tooltipText: frontmatter["tooltip"],
            descriptionText: frontmatter["description"],
            template: content // Full file content — wrapUserText strips frontmatter at runtime
        )
    }

    /// Generates a deterministic UUID-like string from an input string using simple hashing.
    private func deterministicUUID(from input: String) -> String {
        var hash: UInt64 = 5381
        for byte in input.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let hex = String(format: "%016llx", hash)
        let padded = hex.padding(toLength: 32, withPad: "0", startingAt: 0)
        let idx = padded.startIndex
        let i = { padded.index(idx, offsetBy: $0) }
        return "\(padded[idx ..< i(8)])-\(padded[i(8) ..< i(12)])-\(padded[i(12) ..< i(16)])-\(padded[i(16) ..< i(20)])-\(padded[i(20) ..< i(32)])"
    }

    // MARK: Create / Clone

    /// Creates a new custom workflow file from scratch.
    @discardableResult
    func createWorkflow(name: String) throws -> AgentWorkflowDefinition {
        let id = UUID()
        let content = Self.generateMarkdown(
            id: id,
            name: name,
            icon: "gearshape.fill",
            accentColor: nil,
            tooltip: nil,
            description: "A custom workflow",
            templateBody: """
            # \(name)

            $ARGUMENTS
            """
        )
        return try writeWorkflowFile(id: id, name: name, content: content)
    }

    /// Clones a built-in workflow into a custom file with a new name.
    @discardableResult
    func cloneBuiltIn(_ builtIn: AgentWorkflow, name: String) throws -> AgentWorkflowDefinition {
        let id = UUID()
        let templateBody = AgentWorkflowDefinition.stripYAMLFrontmatter(builtIn.template)
        let content = Self.generateMarkdown(
            id: id,
            name: name,
            icon: builtIn.iconName,
            accentColor: nil,
            tooltip: builtIn.tooltipText,
            description: builtIn.descriptionText,
            templateBody: templateBody
        )
        return try writeWorkflowFile(id: id, name: name, content: content)
    }

    /// Deletes a custom workflow file.
    func deleteWorkflow(_ definition: AgentWorkflowDefinition) throws {
        guard let url = fileURL(for: definition) else { return }
        try FileManager.default.removeItem(at: url)
        refresh()
    }

    /// Returns the file URL for a custom workflow (for Finder reveal).
    func fileURL(for definition: AgentWorkflowDefinition) -> URL? {
        guard let customID = definition.customID else { return nil }
        return fileURLsByID[customID]
    }

    // MARK: Helpers

    private static func sanitizedFilename(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_ "))
        let sanitized = name.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(sanitized))
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return result.isEmpty ? "workflow" : result
    }

    private func writeWorkflowFile(id: UUID, name: String, content: String) throws -> AgentWorkflowDefinition {
        let dir = try Self.ensureWorkflowsDirectoryExists()
        let slug = Self.sanitizedFilename(from: name)
        let fileURL = uniqueWorkflowFileURL(in: dir, baseSlug: slug)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        refresh()
        return customWorkflows.first(where: { $0.customID == id })
            ?? AgentWorkflowDefinition(customID: id, displayName: "New Workflow")
    }

    private func uniqueWorkflowFileURL(in directory: URL, baseSlug: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(baseSlug).md")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseSlug)-\(suffix).md")
            suffix += 1
        }
        return candidate
    }

    static func generateMarkdown(
        id: UUID,
        name: String,
        icon: String?,
        accentColor: String?,
        tooltip: String?,
        description: String?,
        templateBody: String
    ) -> String {
        var lines = ["---"]
        lines.append("id: \(id.uuidString)")
        lines.append("name: \"\(name)\"")
        if let icon { lines.append("icon: \"\(icon)\"") }
        if let accentColor { lines.append("accent_color: \"\(accentColor)\"") }
        if let tooltip { lines.append("tooltip: \"\(tooltip)\"") }
        if let description { lines.append("description: \"\(description)\"") }
        lines.append("---")
        lines.append("")
        lines.append(templateBody)
        return lines.joined(separator: "\n")
    }

    // MARK: Finder integration

    /// Opens the Workflows folder in Finder.
    func openInFinder() {
        let url = Self.workflowsDirectoryURL
        try? Self.ensureWorkflowsDirectoryExists()
        NSWorkspace.shared.open(url)
    }

    /// Reveals a specific workflow file in Finder.
    func revealInFinder(_ definition: AgentWorkflowDefinition) {
        guard let url = fileURL(for: definition) else {
            openInFinder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Featured workflow helpers

    private func syncFeaturedWorkflowsWithCurrentCatalog() {
        updateFeaturedWorkflowIDs(featuredWorkflowIDs)
    }

    private func updateFeaturedWorkflowIDs(_ ids: [String]) {
        let normalized = normalizedFeaturedWorkflowIDs(ids)
        guard featuredWorkflowIDs != normalized else {
            persistFeaturedWorkflowIDs()
            return
        }
        featuredWorkflowIDs = normalized
        persistFeaturedWorkflowIDs()
    }

    private func persistFeaturedWorkflowIDs() {
        UserDefaults.standard.set(featuredWorkflowIDs, forKey: Self.featuredWorkflowIDsKey)
    }

    private func normalizedFeaturedWorkflowIDs(_ ids: [String]) -> [String] {
        var orderedIDs: [String] = []
        var seenIDs: Set<String> = []

        func appendIfValid(_ workflowID: String) {
            guard !seenIDs.contains(workflowID) else { return }
            guard let workflow = resolveWorkflow(workflowID) else { return }
            guard !isHiddenBuiltIn(workflow) else { return }
            orderedIDs.append(workflowID)
            seenIDs.insert(workflowID)
        }

        for workflowID in ids {
            guard orderedIDs.count < Self.maxFeaturedWorkflowCount else { break }
            appendIfValid(workflowID)
        }

        return Array(orderedIDs.prefix(Self.maxFeaturedWorkflowCount))
    }

    private func isHiddenBuiltIn(_ workflow: AgentWorkflowDefinition) -> Bool {
        guard let builtIn = workflow.builtInWorkflow else { return false }
        return isBuiltInHidden(builtIn)
    }

    func resolveWorkflowReference(_ reference: String) -> AgentWorkflowDefinition? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = allWorkflows.first(where: { $0.id == trimmed }) {
            return direct
        }
        return allWorkflows.first(where: {
            $0.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
        })
    }

    private func resolveWorkflow(_ workflowID: String) -> AgentWorkflowDefinition? {
        featureableWorkflows.first(where: { $0.id == workflowID })
    }
}
