import Foundation
import Logging
import RepoPromptDomainRuntime

@MainActor
protocol MCPAppToolProviding {
    var group: MCPAppToolGroup { get }
    func buildTools() -> [Tool]
}

enum MCPAppToolCatalogMaterializationError: Error, Equatable, CustomStringConvertible {
    case invalidProviderTool(name: String, reason: String)
    case invalidSharedBinding(name: String, reason: String)
    case duplicateTool(String)
    case missingCanonicalTools([String])
    case nonCanonicalTools([String])

    var description: String {
        switch self {
        case let .invalidProviderTool(name, reason):
            "Invalid app adapter tool '\(name)': \(reason)"
        case let .invalidSharedBinding(name, reason):
            "Invalid shared domain binding '\(name)': \(reason)"
        case let .duplicateTool(name):
            "Duplicate MCP tool definition: \(name)"
        case let .missingCanonicalTools(names):
            "App tool registration is missing canonical tools: \(names.joined(separator: ", "))"
        case let .nonCanonicalTools(names):
            "App tool registration contains non-canonical tools: \(names.joined(separator: ", "))"
        }
    }
}

@MainActor
final class MCPAppToolCatalogRegistration: WindowScopedService {
    let domainRegistrationID = MCPDomainToolRegistrationID()
    let windowID: Int

    private let providers: [any MCPAppToolProviding]
    private let sharedBindings: [MCPDomainToolBinding]
    private let runtime: MCPAppToolBinder
    private let requiredToolNames: Set<String>
    private let logger = Logger(label: "com.repoprompt.mcp.app-tool-catalog")
    private var toolsCache: [Tool]?
    private(set) var materializationErrorDescription: String?

    init(
        windowID: Int,
        providers: [any MCPAppToolProviding],
        sharedBindings: [MCPDomainToolBinding] = [],
        runtime: MCPAppToolBinder,
        requiredToolNames: Set<String> = Set(MCPAppToolGroup.orderedToolNames)
    ) {
        #if DEBUG || EDIT_FLOW_PERF
            let constructionState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.construction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.construction, constructionState) }
        #endif
        self.windowID = windowID
        self.providers = providers
        self.sharedBindings = sharedBindings
        self.runtime = runtime
        self.requiredToolNames = requiredToolNames
    }

    var longRunningInteractionAdapter: DomainLongRunningInteractionAdapter? {
        providers.compactMap { ($0 as? MCPAskUserToolProvider)?.domainInteractionAdapter }.first
    }

    /// Read-only catalog inspection materializes the same canonical projection used by startup.
    /// Authoritative registration calls `materializeTools()` directly so failures are thrown;
    /// the nonthrowing `WindowScopedService` protocol can only expose an empty failed-closed view.
    var tools: [Tool] {
        get async {
            do {
                return try materializeTools()
            } catch {
                materializationErrorDescription = String(reflecting: error)
                logger.error("App MCP tool catalog materialization failed", metadata: [
                    "window_id": "\(windowID)",
                    "error": "\(String(reflecting: error))"
                ])
                return []
            }
        }
    }

    func materializeTools() throws -> [Tool] {
        #if DEBUG || EDIT_FLOW_PERF
            let materializationState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization, materializationState) }
        #endif
        if let toolsCache { return toolsCache }
        materializationErrorDescription = nil

        var providersByGroup: [MCPAppToolGroup: [any MCPAppToolProviding]] = [:]
        for provider in providers {
            providersByGroup[provider.group, default: []].append(provider)
        }

        var toolsByName: [String: Tool] = [:]
        for group in MCPAppToolGroup.allCases {
            for provider in providersByGroup[group] ?? [] {
                for implementation in provider.buildTools() {
                    let canonical: Tool
                    do {
                        canonical = try Tool(canonicalizing: implementation)
                    } catch {
                        throw MCPAppToolCatalogMaterializationError.invalidProviderTool(
                            name: implementation.name,
                            reason: String(reflecting: error)
                        )
                    }
                    guard toolsByName.updateValue(canonical, forKey: canonical.name) == nil else {
                        throw MCPAppToolCatalogMaterializationError.duplicateTool(canonical.name)
                    }
                }
            }
        }

        for binding in sharedBindings {
            let tool: Tool
            do {
                // Shared bindings are raw domain implementations, so the app binder is
                // applied exactly once here. Provider tools above are already bound.
                tool = try Tool(domainBinding: binding, runtime: runtime)
            } catch {
                throw MCPAppToolCatalogMaterializationError.invalidSharedBinding(
                    name: binding.definition.name,
                    reason: String(reflecting: error)
                )
            }
            guard toolsByName.updateValue(tool, forKey: tool.name) == nil else {
                throw MCPAppToolCatalogMaterializationError.duplicateTool(tool.name)
            }
        }

        let materializedNames = Set(toolsByName.keys)
        let canonicalNames = Set(MCPAppToolGroup.orderedToolNames)
        let unexpected = materializedNames.subtracting(canonicalNames).sorted()
        guard unexpected.isEmpty else {
            throw MCPAppToolCatalogMaterializationError.nonCanonicalTools(unexpected)
        }
        let missing = requiredToolNames.subtracting(materializedNames).sorted()
        guard missing.isEmpty else {
            throw MCPAppToolCatalogMaterializationError.missingCanonicalTools(missing)
        }

        let built = MCPAppToolGroup.orderedToolNames.compactMap { toolsByName[$0] }
        toolsCache = built
        return built
    }

    func invalidateToolsCache() {
        #if DEBUG || EDIT_FLOW_PERF
            let invalidateToolsCacheState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache, invalidateToolsCacheState) }
        #endif
        toolsCache = nil
    }
}
