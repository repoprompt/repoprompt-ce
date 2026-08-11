//
//  MCPPromptRegistry.swift
//  RepoPrompt
//
//  Registry of MCP prompt templates exposed via prompts/list and prompts/get.
//  These are workflow prompts that coding agents can invoke to get structured
//  guidance for common tasks like building features or investigating systems.
//

import Foundation
import MCP
import RepoPromptShared

/// Registry for MCP prompt templates.
/// Exposes RepoPrompt's built-in workflow prompts (rp-build, rp-investigate)
/// via the MCP prompts/list and prompts/get protocol methods.
enum MCPPromptRegistry {
    // MARK: - Prompt Definitions

    /// A prompt definition with metadata and template content.
    struct Definition {
        let name: String
        let description: String
        let arguments: [Prompt.Argument]
        /// Template content with $ARGUMENTS placeholder for substitution
        let template: String
    }

    /// All available prompt definitions.
    /// These correspond to managed RepoPrompt workflow skills/commands.
    static let definitions: [Definition] = WorkflowPromptCatalog.mcpPromptDescriptors.map { descriptor in
        Definition(
            name: descriptor.name,
            description: descriptor.description,
            arguments: descriptor.arguments.map { argument in
                Prompt.Argument(
                    name: argument.name,
                    description: argument.description,
                    required: argument.required
                )
            },
            template: RepoPromptWorkflowPrompts.render(id: descriptor.id, variant: .mcp)
        )
    }

    // MARK: - Public API

    /// Returns the list of available prompts for prompts/list.
    static func listPrompts() -> [Prompt] {
        definitions.map { def in
            Prompt(
                name: def.name,
                description: def.description,
                arguments: def.arguments
            )
        }
    }

    /// Gets a specific prompt with argument substitution for prompts/get.
    /// - Parameters:
    ///   - name: The prompt name to retrieve
    ///   - arguments: Optional arguments to substitute into the template
    /// - Returns: The prompt result with rendered messages
    /// - Throws: MCPError if the prompt is not found
    static func getPrompt(named name: String, arguments: [String: Value]?) throws -> GetPrompt.Result {
        guard let definition = definitions.first(where: { $0.name == name }) else {
            throw MCPError.invalidParams("Unknown prompt: \(name)")
        }

        let resolvedArgs = resolveArgumentsText(from: arguments, definition: definition)
        let renderedContent = definition.template.replacingOccurrences(of: "$ARGUMENTS", with: resolvedArgs)

        // Strip YAML frontmatter if present (between --- markers at the start)
        let cleanedContent = RepoPromptWorkflowPrompts.stripYAMLFrontmatter(renderedContent)

        return GetPrompt.Result(
            description: definition.description,
            messages: [
                .user(.text(text: cleanedContent))
            ]
        )
    }

    // MARK: - Private Helpers

    /// Resolves arguments to a text string for $ARGUMENTS substitution.
    /// Looks for the primary argument first (task/issue), then falls back to
    /// joining all arguments.
    private static func resolveArgumentsText(from arguments: [String: Value]?, definition: Definition) -> String {
        guard let arguments, !arguments.isEmpty else {
            return ""
        }

        // Try the primary argument name first (the required one)
        if let primaryArg = definition.arguments.first(where: { $0.required == true }),
           let value = arguments[primaryArg.name]
        {
            return extractStringValue(from: value)
        }

        // Fallback: try common argument names
        for key in ["task", "issue", "problem", "scope", "target", "arguments", "ARGUMENTS", "input", "query"] {
            if let value = arguments[key] {
                return extractStringValue(from: value)
            }
        }

        // Last resort: join all key-value pairs
        let sortedKeys = arguments.keys.sorted()
        let lines = sortedKeys.compactMap { key -> String? in
            guard let value = arguments[key] else { return nil }
            let stringValue = extractStringValue(from: value)
            return "\(key): \(stringValue)"
        }
        return lines.joined(separator: "\n")
    }

    /// Extracts a string value from an MCP Value.
    private static func extractStringValue(from value: Value) -> String {
        if let str = value.stringValue {
            return str
        }
        // For non-string values, use the description
        return String(describing: value)
    }
}
