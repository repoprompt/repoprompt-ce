import Foundation

@MainActor
protocol MCPWindowToolProviding {
    var group: MCPWindowToolGroup { get }
    func buildTools() -> [Tool]
}

@MainActor
final class MCPWindowToolCatalogService: WindowScopedService {
    let windowID: Int

    private let providers: [any MCPWindowToolProviding]
    private var toolsCache: [Tool]?

    init(windowID: Int, providers: [any MCPWindowToolProviding]) {
        #if DEBUG || EDIT_FLOW_PERF
            let constructionState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.construction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.construction, constructionState) }
        #endif
        self.windowID = windowID
        self.providers = providers
    }

    var tools: [Tool] {
        get async {
            #if DEBUG || EDIT_FLOW_PERF
                let actorBodyTotalState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsActorBodyTotal)
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsActorBodyTotal, actorBodyTotalState) }
            #endif
            if let toolsCache {
                return toolsCache
            }
            #if DEBUG || EDIT_FLOW_PERF
                let materializationState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization)
                defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.serviceToolLookupWindowCatalogToolsMaterialization, materializationState) }
            #endif
            var providersByGroup: [MCPWindowToolGroup: [any MCPWindowToolProviding]] = [:]
            for provider in providers {
                providersByGroup[provider.group, default: []].append(provider)
            }
            let built = MCPWindowToolGroup.allCases.flatMap { group in
                providersByGroup[group]?.flatMap { $0.buildTools() } ?? []
            }
            toolsCache = built
            return built
        }
    }

    func invalidateToolsCache() {
        #if DEBUG || EDIT_FLOW_PERF
            let invalidateToolsCacheState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.invalidateToolsCache, invalidateToolsCacheState) }
        #endif
        toolsCache = nil
    }
}
