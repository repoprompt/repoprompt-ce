import Foundation
import MCP

extension MCPServerViewModel {
    @MainActor
    @discardableResult
    func updateCurrentTabPrompt(
        toolName: String,
        mutation: (inout String) -> Void
    ) async throws -> String {
        var (connectionID, context) = try await contextForCurrentRequest(toolName: toolName)
        try Task.checkCancellation()
        if context.runID == nil {
            // A binding caches presentation, not write authority. Background-tab commits do not
            // publish snapshots to other connections, and an active editor can be newer than its
            // stored tab. Read the exact owner now, then transform and store without suspension.
            guard let workspaceID = context.workspaceID,
                  let current = workspaceManager?.collectMCPTabContextComposeSnapshot(
                      tabID: context.tabID,
                      workspaceID: workspaceID,
                      captureActiveUIState: true,
                      flushPendingUISelection: false
                  )
            else {
                throw MCPError.invalidParams("The bound tab is no longer available for \(toolName)")
            }
            context.promptText = current.snapshot.promptText
        }
        let previousPrompt = context.promptText
        mutation(&context.promptText)
        if context.promptText != previousPrompt {
            let (cleanPrompt, taskName) = stripTaskNameTag(from: context.promptText)
            context.promptText = cleanPrompt
            if let taskName,
               !taskName.isEmpty
            {
                let sanitized = sanitizeTaskName(taskName)
                if !sanitized.isEmpty {
                    renameComposeTabIfDefault(tabID: context.tabID, newName: sanitized)
                }
            }
        }
        if context.runID == nil {
            guard let workspaceID = context.workspaceID,
                  let manager = workspaceManager,
                  var tab = manager.composeTab(for: WorkspaceSelectionIdentity(
                      workspaceID: workspaceID,
                      tabID: context.tabID
                  ))
            else {
                throw MCPError.invalidParams("The bound tab is no longer available for \(toolName)")
            }
            // Prompt commands own only the text. Preserve canonical meta prompts, selection,
            // overrides, and any task-name update performed above.
            tab.promptText = context.promptText
            guard manager.updateComposeTabStoredOnly(tab, inWorkspaceID: workspaceID) else {
                throw MCPError.invalidParams("The bound tab is no longer available for \(toolName)")
            }
            context.selectedMetaPromptIDs = tab.selectedMetaPromptIDs
            tabContextByConnectionID[connectionID] = context
            if manager.activeWorkspace?.id == workspaceID,
               manager.activeWorkspace?.activeComposeTabID == tab.id,
               promptVM.activeComposeTabID == tab.id
            {
                promptVM.promptText = tab.promptText
            }
        } else {
            // Run-scoped Context Builder edits keep their existing snapshot-based commit behavior.
            // Ordinary prompt reads also retain their current snapshot policy.
            tabContextByConnectionID[connectionID] = context
            await pushVirtualContextToUI(context)
        }
        return context.promptText
    }

    private func stripTaskNameTag(from prompt: String) -> (cleanPrompt: String, taskName: String?) {
        guard !prompt.isEmpty else {
            return (prompt, nil)
        }

        // Pattern supports:
        // 1. <taskname="value"/> - double-quoted, self-closing
        // 2. <taskname='value'/> - single-quoted, self-closing
        // 3. <taskname=value/>   - unquoted, self-closing
        // 4. <taskname="value">  - double-quoted, not self-closing
        // 5. <taskname='value'>  - single-quoted, not self-closing
        // 6. <taskname=value>    - unquoted, not self-closing
        let pattern = #"^[ \t]*<taskname=(?:"([^"]*)"|'([^']*)'|([^/>]+?))\s*/?>[ \t]*(?:\r?\n)?"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .anchorsMatchLines]
        ) else {
            return (prompt, nil)
        }

        let fullRange = NSRange(prompt.startIndex ..< prompt.endIndex, in: prompt)
        let matches = regex.matches(in: prompt, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return (prompt, nil)
        }

        var extractedName: String?
        if let first = matches.first {
            // Check capture groups 1-3 (double-quoted, single-quoted, unquoted)
            for groupIndex in 1 ... 3 {
                let range = first.range(at: groupIndex)
                if range.location != NSNotFound,
                   let nameRange = Range(range, in: prompt)
                {
                    let captured = String(prompt[nameRange])
                    if !captured.isEmpty {
                        extractedName = captured.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
        }

        // Return original prompt unchanged, just extract the task name
        return (prompt, extractedName)
    }

    private func sanitizeTaskName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let filtered = collapsed.filter { $0 != "\n" && $0 != "\r" && $0 != "\t" && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
        guard !filtered.isEmpty else { return "" }

        let maxLength = 80
        if filtered.count > maxLength {
            let end = filtered.index(filtered.startIndex, offsetBy: maxLength)
            return String(filtered[..<end])
        }
        return filtered
    }

    @MainActor
    private func renameComposeTabIfDefault(tabID: UUID, newName: String) {
        guard let tab = workspaceManager?.composeTab(with: tabID),
              tab.hasDefaultName,
              tab.name != newName else { return }
        promptVM.renameComposeTab(tabID, to: newName)
    }
}
