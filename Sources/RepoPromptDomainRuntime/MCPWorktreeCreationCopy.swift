import Foundation
import MCP

/// Creation-location guidance belongs to the advertised canonical contract, not just
/// legacy app providers or conversation history. This changes metadata, never authority.
package enum MCPWorktreeCreationCopy {
    package static let temporaryLocationPolicy = "Never choose `/tmp`, `/private/tmp`, `/var/tmp`, `$TMPDIR`, macOS `/var/folders` temporary directories, or symlink aliases of temporary locations unless the user explicitly requests that location. Sandbox access, a dirty checkout, and historical examples are not location consent. A refused mutation must not be retried through shell, scripts, native tools, or escalation."

    private static let manageWorktreeDefault = "App-backed creation: omit `path` for the persistent `.repoprompt-worktrees` default."
    package static let manageWorktreeSummary = "Manage Git worktrees, per-agent-session worktree bindings, and session-bound worktree merges. \(manageWorktreeDefault)"
    package static let manageWorktreeUsage = """
    **Creation defaults (app backend)**
    For normal creation use `{"op":"create"}` (add `repo_root` when the session has multiple bindings, and `branch` and `base_ref` as needed) and omit `path` and `allow_external_path`. RepoPrompt chooses its `.repoprompt-worktrees` container beside the main repository. Do not invent a path, look for a writable scratch directory, or ask the user to choose a location for ordinary creation.
    Supply an explicit path only for a user-requested location. Selecting a location does not grant creation authority or bypass existing path checks.
    \(temporaryLocationPolicy)
    Direct headless creation requires a user-provided explicit `path`; it does not provide the app-managed default. If no location was supplied, request one rather than inventing a temporary destination.
    """
    package static let manageWorktreePathProperty = "Create: optional explicit user-requested absolute path. App backend: omit this field to use the persistent `.repoprompt-worktrees` default; do not guess a directory. Temporary locations require an explicit user request. External paths also require allow_external_path=true. Direct headless creation requires path."
    package static let allowExternalPathProperty = "Create: allow an explicit path outside the app-managed container. Omit for normal app-backed creation. This flag does not establish user consent for the location or bypass path checks."

    private static let agentRunDefault = "For app-backed isolation, set `worktree_create=true` and omit `worktree_path` for the persistent `.repoprompt-worktrees` default."
    package static let agentRunSummary = "Spawn and control Agent Mode sessions. `start` always creates a new session/tab; use `steer` to continue an existing session. \(agentRunDefault)"
    package static let agentRunUsage = """
    **Creation defaults (app backend)**
    For an isolated new child use `{"op":"start","message":"<task>","worktree_create":true}` and omit `worktree_path` and `allow_external_worktree_path`. RepoPrompt chooses its `.repoprompt-worktrees` container beside the main repository; do not choose a temporary directory or ask for a location for ordinary creation. PRIMARY-only creation rules still apply; `worktree_create` suppresses parent worktree inheritance and binds only the requested worktree.
    \(temporaryLocationPolicy)
    Direct headless starts can bind existing worktrees only; they do not create worktrees.
    """
    package static let agentExploreUsage = "For isolation, set `worktree_create=true` and omit `worktree_path` and `allow_external_worktree_path` to use the app-managed `.repoprompt-worktrees` default. Do not invent a destination or ask for a location for ordinary creation. \(temporaryLocationPolicy)"
    package static let agentWorktreePathProperty = "[start + worktree_create] Optional explicit user-requested absolute path (or ~/...). App backend: omit this field to use the persistent `.repoprompt-worktrees` default. Temporary locations require an explicit user request. External paths also require allow_external_worktree_path=true. Direct headless starts cannot create worktrees."
    package static let allowExternalWorktreePathProperty = "[start + worktree_create] Allow an explicit path outside the app-managed container. Omit for normal app-backed creation. This flag does not establish user consent for the location or bypass path checks."

    package static func applying(to definition: MCPDomainToolDefinition) -> MCPDomainToolDefinition {
        let defaultSentence: String
        let usage: String
        let propertyDescriptions: [String: String]
        switch definition.name {
        case MCPWindowToolName.manageWorktree:
            defaultSentence = manageWorktreeDefault
            usage = manageWorktreeUsage
            propertyDescriptions = ["path": manageWorktreePathProperty, "allow_external_path": allowExternalPathProperty]
        case MCPWindowToolName.agentRun:
            defaultSentence = agentRunDefault
            usage = agentRunUsage
            propertyDescriptions = ["worktree_path": agentWorktreePathProperty, "allow_external_worktree_path": allowExternalWorktreePathProperty]
        default:
            return definition
        }

        // Put the default in the short summary as well as parameter help: neither
        // schema discovery nor rebuilding a binding should depend on chat history.
        let newline = definition.description.firstIndex(of: "\n") ?? definition.description.endIndex
        let firstLine = String(definition.description[..<newline])
        let summary = firstLine + (firstLine.contains(defaultSentence) ? "" : " " + defaultSentence)
        let suffix = String(definition.description[newline...])
        let description = summary + (definition.description.contains(usage) ? "" : "\n\n" + usage) + suffix
        var inputSchema = definition.inputSchema
        if case var .object(schema) = inputSchema,
           case var .object(properties)? = schema["properties"]
        {
            for (name, text) in propertyDescriptions {
                guard case var .object(property)? = properties[name] else { continue }
                property["description"] = .string(text)
                properties[name] = .object(property)
            }
            schema["properties"] = .object(properties)
            inputSchema = .object(schema)
        }
        return MCPDomainToolDefinition(
            name: definition.name,
            description: description,
            inputSchema: inputSchema,
            annotations: definition.annotations,
            isEnabledByDefault: definition.isEnabledByDefault
        )
    }
}
