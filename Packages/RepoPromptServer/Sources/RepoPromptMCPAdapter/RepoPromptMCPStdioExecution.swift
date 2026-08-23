import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared

/// Canonical stdio presentation for a host-issued MCP serving capability.
///
/// This type owns no authority, project, session, or persistence state. The
/// private helper supplies a `RepoPromptMCPAdapter` assembled from its Host
/// composition; Server child transports may use the same presentation without
/// gaining authority construction privileges.
public enum RepoPromptMCPStdioExecution {
    public static func run(
        adapter: RepoPromptMCPAdapter,
        binding: RepoPromptMCPBinding,
        isRootSession: Bool,
        policyProfile: MCPClientToolPolicyProfile = .direct,
        logger: Logger = Logger(label: "com.repoprompt.ce.mcp.headless-stdio") { _ in
            SwiftLogNoOpLogHandler()
        }
    ) async throws {
        let server = Server(
            name: "RepoPrompt CE",
            version: "1.3.0",
            title: "RepoPrompt CE Headless",
            instructions: "Direct AppKit-free RepoPrompt MCP runtime.",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .init(strict: true, responseSendTimeout: .seconds(5))
        )
        let classification = MCPClientToolPolicyCatalog.classification(for: policyProfile)
        await server.withMethodHandler(ListTools.self) { _ in
            let advertised = try await adapter.advertisedToolNames(isRootSession: isRootSession)
            let restricted = MCPDomainToolCatalog
                .toolNames(for: classification.restrictedCapabilities)
            let additionallyGranted = MCPDomainToolCatalog
                .toolNames(for: classification.grantedCapabilities)
            let visible = advertised.filter { toolName in
                !restricted.contains(toolName)
                    && (
                        !MCPClientToolPolicyCatalog.policyGatedToolNames.contains(toolName)
                            || additionallyGranted.contains(toolName)
                    )
                    && MCPClientToolPolicyCatalog.shouldAdvertise(
                        toolName: toolName,
                        role: classification.role,
                        allowsAgentExternalControlTools: classification.allowsAgentExternalControlTools
                    )
            }
            return ListTools.Result(tools: MCPDomainCanonicalToolDefinitions.definitions.compactMap { definition in
                guard visible.contains(definition.name) else { return nil }
                let annotations = definition.annotations.projected(
                    for: classification.annotationProfile
                )
                return MCP.Tool(
                    name: definition.name,
                    description: definition.description,
                    inputSchema: definition.inputSchema,
                    annotations: .init(
                        title: annotations.title,
                        readOnlyHint: annotations.readOnlyHint,
                        destructiveHint: annotations.destructiveHint,
                        idempotentHint: annotations.idempotentHint,
                        openWorldHint: annotations.openWorldHint
                    )
                )
            })
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let advertised = try await adapter.advertisedToolNames(isRootSession: isRootSession)
                guard advertised.contains(params.name) else {
                    return errorResult("Tool is unavailable for this client policy: \(params.name)")
                }
                let arguments = params.arguments ?? [:]
                let data = try JSONEncoder().encode(arguments)
                let requestIdentity = try Self.requestTimelineIdentity(
                    metadataAppInvocationID: params._meta?[MCPRequestTimelineTransportMetadata.appInvocationIDKey]?.stringValue,
                    inherited: MCPRequestTimelineContext.current
                )
                let invocationBinding = Self.invocationBinding(
                    binding,
                    timelineIdentity: requestIdentity
                )
                let result = try await MCPRequestTimelineContext.$current.withValue(requestIdentity) {
                    try await adapter.invoke(
                        toolName: params.name,
                        argumentsJSON: data,
                        binding: invocationBinding
                    )
                }
                return CallTool.Result(
                    content: [.text(text: String(decoding: result, as: UTF8.self), annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return errorResult(String(describing: error))
            }
        }

        let transport = StdioTransport(logger: logger)
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
        await server.stop()
    }

    package static func requestTimelineIdentity(
        metadataAppInvocationID: String?,
        inherited: MCPRequestTimelineIdentity?
    ) throws -> MCPRequestTimelineIdentity? {
        guard let metadataAppInvocationID else { return inherited }
        guard let appInvocationID = MCPRequestTimelineTransportMetadata.normalizedAppInvocationID(
            metadataAppInvocationID
        ) else {
            throw MCPError.invalidParams("Invalid host-issued MCP application invocation identity")
        }
        return MCPRequestTimelineTransportMetadata.identity(
            appInvocationID: appInvocationID,
            inheriting: inherited
        )
    }

    package static func invocationBinding(
        _ binding: RepoPromptMCPBinding,
        timelineIdentity: MCPRequestTimelineIdentity?
    ) -> RepoPromptMCPBinding {
        binding.withAppInvocationID(timelineIdentity?.appInvocationID)
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
