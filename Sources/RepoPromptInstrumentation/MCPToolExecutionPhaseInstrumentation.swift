import Foundation

package enum MCPToolExecutionHandlerPhase: String, Equatable, Sendable {
    case manageSelectionAutoSelectionDrain = "manage_selection.auto_selection_drain"
    case manageSelectionIngressWait = "manage_selection.ingress_wait"
    case manageSelectionConstruction = "manage_selection.selection_construction"
    case manageSelectionPersistence = "manage_selection.persistence"
    case manageSelectionReplyConstruction = "manage_selection.reply_construction"
    case fileActionsPreMutationChecks = "file_actions.pre_mutation_checks"
    case fileActionsCatalogEligibility = "file_actions.catalog_eligibility"
    case fileActionsMutationIO = "file_actions.mutation_io"
    case fileActionsPostMutationCatalog = "file_actions.post_mutation_catalog"
    case fileActionsPostMutationSelection = "file_actions.post_mutation_selection"
    case fileActionsReplyConstruction = "file_actions.reply_construction"
    case readFileRequestResolution = "read_file.request_resolution"
    case readFileContentRead = "read_file.content_read"
    case readFileAutoSelection = "read_file.auto_selection"
    case getFileTreeRequestResolution = "get_file_tree.request_resolution"
    case getFileTreeIngressWait = "get_file_tree.ingress_wait"
    case getFileTreeConstruction = "get_file_tree.construction"
    case promptExportSelectionDrain = "prompt_export.selection_drain"
    case promptExportPresetResolution = "prompt_export.preset_resolution"
    case promptExportContentAssembly = "prompt_export.content_assembly"
    case promptExportMetadataAssembly = "prompt_export.metadata_assembly"
    case promptExportDestinationAuthorization = "prompt_export.destination_authorization"
    case promptExportDurableWrite = "prompt_export.durable_write"
    case promptExportIngressWait = "prompt_export.ingress_wait"
    case promptExportReplyAssembly = "prompt_export.reply_assembly"
    case promptExportFormatting = "prompt_export.formatting"
    case promptExportPublication = "prompt_export.publication"
    // Graph-first get_code_structure execution stages.
    case getCodeStructureSeedResolution = "get_code_structure.seed_resolution"
    case getCodeStructureGraphSnapshot = "get_code_structure.graph_snapshot"
    case getCodeStructureGraphTraversal = "get_code_structure.graph_traversal"
    case getCodeStructureGraphRevalidation = "get_code_structure.graph_revalidation"
    case getCodeStructureRenderDemand = "get_code_structure.render_demand"
    case getCodeStructureFreeze = "get_code_structure.freeze"
    case getCodeStructureRender = "get_code_structure.render"
    case getCodeStructureAssembly = "get_code_structure.assembly"
}

package enum MCPToolExecutionHandlerPhaseTransition: String, Equatable, Sendable {
    case started
    case completed
}

package struct MCPToolExecutionHandlerPhaseSnapshot: Equatable, Sendable {
    package let phase: MCPToolExecutionHandlerPhase
    package let transition: MCPToolExecutionHandlerPhaseTransition
    package let elapsedMilliseconds: Double

    package init(
        phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition,
        elapsedMilliseconds: Double
    ) {
        self.phase = phase
        self.transition = transition
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

package protocol MCPToolExecutionHandlerPhaseRecording: Sendable {
    func report(_ phase: MCPToolExecutionHandlerPhase, transition: MCPToolExecutionHandlerPhaseTransition) async -> MCPToolExecutionHandlerPhaseSnapshot
    func snapshot() -> MCPToolExecutionHandlerPhaseSnapshot?
}

/// Fail-closed default when no request-scoped recorder is injected.
package struct NoopMCPToolExecutionHandlerPhaseRecorder: MCPToolExecutionHandlerPhaseRecording {
    package init() {}

    package func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition
    ) async -> MCPToolExecutionHandlerPhaseSnapshot {
        MCPToolExecutionHandlerPhaseSnapshot(phase: phase, transition: transition, elapsedMilliseconds: 0)
    }

    package func snapshot() -> MCPToolExecutionHandlerPhaseSnapshot? { nil }
}

package protocol MCPToolExecutionHandlerPhaseRecorderFactory: Sendable {
    func make(
        origin: Duration,
        now: @escaping @Sendable () async -> Duration
    ) -> any MCPToolExecutionHandlerPhaseRecording
}

/// An unconfigured lower-layer owner does not reach into app diagnostics.
package struct NoopMCPToolExecutionHandlerPhaseRecorderFactory: MCPToolExecutionHandlerPhaseRecorderFactory {
    package init() {}

    package func make(
        origin _: Duration,
        now _: @escaping @Sendable () async -> Duration
    ) -> any MCPToolExecutionHandlerPhaseRecording {
        NoopMCPToolExecutionHandlerPhaseRecorder()
    }
}

package enum MCPToolExecutionHandlerPhaseContext {
    @TaskLocal
    package static var recorder: (any MCPToolExecutionHandlerPhaseRecording)?

    #if DEBUG
        private final class DebugState: @unchecked Sendable {
            let lock = NSLock()
            var sink: (@Sendable (MCPToolExecutionHandlerPhaseSnapshot) -> Void)?
        }

        private static let debugState = DebugState()
    #endif

    package static func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition = .started
    ) async {
        guard let recorder else { return }
        await report(phase, transition: transition, using: recorder)
    }

    @discardableResult
    package static func report(
        _ phase: MCPToolExecutionHandlerPhase,
        transition: MCPToolExecutionHandlerPhaseTransition = .started,
        using recorder: any MCPToolExecutionHandlerPhaseRecording
    ) async -> MCPToolExecutionHandlerPhaseSnapshot {
        let snapshot = await recorder.report(phase, transition: transition)
        #if DEBUG
            let sink = debugState.lock.withLock { debugState.sink }
            sink?(snapshot)
        #endif
        return snapshot
    }

    #if DEBUG
        package static func setTestSink(_ sink: (@Sendable (MCPToolExecutionHandlerPhaseSnapshot) -> Void)?) {
            debugState.lock.lock()
            debugState.sink = sink
            debugState.lock.unlock()
        }
    #endif
}

extension Duration {
    package var mcpSeconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    package var mcpMilliseconds: Double {
        mcpSeconds * 1000
    }
}
