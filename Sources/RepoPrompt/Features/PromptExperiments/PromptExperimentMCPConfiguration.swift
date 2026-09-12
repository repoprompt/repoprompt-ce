#if DEBUG
    import CryptoKit
    import Foundation
    import RepoPromptDomainRuntime

    /// The candidate changes wording, never executable identity, schemas, or tool authority.
    struct PromptExperimentMCPConfiguration: Codable, Equatable {
        static let allowedTools: Set<String> = ["read_file", "file_search", "get_file_tree", "get_code_structure"]
        static let sdkVersion = "1.30.0"
        var toolNames: [String]
        /// system_prompt or tool_description_<allowed tool name>, using upstream component semantics.
        var component: String
        var toolDefinitionsJson: String? = nil
        var serverSha256: String? = nil

        func validate() throws {
            guard !toolNames.isEmpty, Set(toolNames).count == toolNames.count,
                  Set(toolNames).isSubset(of: Self.allowedTools),
                  component == "system_prompt" || toolNames.contains(where: { component == "tool_description_" + $0 })
            else {
                throw PromptExperimentAuthorityError.invalidDraft("MCP requires distinct read-only RPCE tool names and system_prompt or tool_description_<selected tool> as its component. Remote servers and control tools are not admitted.")
            }
        }

        static func serverURL() throws -> URL {
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/repoprompt-mcp")
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The packaged headless MCP executable is unavailable.")
            }
            return url
        }

        func resolved() throws -> Self {
            try validate()
            let definitions = try toolNames.map { name in
                guard let definition = MCPDomainCanonicalToolDefinitions.definition(named: name) else {
                    throw PromptExperimentAuthorityError.invalidDraft("The requested MCP tool has no canonical schema.")
                }
                return definition
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var value = self
            value.toolDefinitionsJson = try String(decoding: encoder.encode(definitions), as: UTF8.self)
            value.serverSha256 = try SHA256.hash(data: Data(contentsOf: Self.serverURL(), options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            return value
        }

        func verifyResolved() throws {
            guard try self == resolved() else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("MCP executable or tool schemas changed; clone and reseal this experiment before running.")
            }
        }
    }
#endif
