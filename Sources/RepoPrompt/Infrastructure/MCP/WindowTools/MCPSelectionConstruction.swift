import Foundation
import MCP

/// Outputs of the `manage_selection` construction interval.
struct MCPSelectionConstructionOutcome {
    var snapshot: MCPServerViewModel.TabContextSnapshot
    var frozenReviewContext: FrozenPromptGitReviewContext?
    var artifactResolution: MCPManageSelectionArtifactResolution
}

/// The awaited portion of `manage_selection` between ingress and operation-specific mutation.
///
/// This is separated from `MCPSelectionToolProvider` so the awaited ordering can be driven
/// directly against the injected capabilities without window, schema, or reply fixtures. The
/// provider and the tests must enter through here, otherwise a passing test would prove nothing
/// about the ordering production actually runs.
@MainActor
enum MCPSelectionConstruction {
    /// Operations that consult frozen Git review context and `_git_data` artifact aliases.
    private static let artifactAwareOperations: Set<String> = ["add", "remove", "set", "preview"]

    /// Opens a child interval, awaits the dependency, and only then closes it.
    ///
    /// The recorder keeps the latest snapshot, so a dependency that ignores cancellation leaves
    /// its child phase reading `started` through deadline and cleanup grace, which is what makes
    /// the watchdog packet name that exact dependency. The cancellation check runs before the
    /// `completed` report so a late return cannot overwrite the attribution.
    private static func attributed<T>(
        _ phase: MCPToolExecutionHandlerPhase,
        _ operation: () async -> T
    ) async throws -> T {
        await MCPToolExecutionHandlerPhaseContext.report(phase)
        let value = await operation()
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(phase, transition: .completed)
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction)
        return value
    }

    static func run(
        snapshot: MCPServerViewModel.TabContextSnapshot,
        op: String,
        mode: String,
        parsedInputs: MCPServerViewModel.ManageSelectionInputs,
        physicalize: (StoredSelection) -> StoredSelection,
        stabilizedVirtualSelection: MCPAppPhysicalCapabilityAdapters.StabilizedVirtualSelection,
        freezePromptGitReviewContext: MCPAppPhysicalCapabilityAdapters.FreezePromptGitReviewContext,
        resolveManageSelectionArtifactInputs: MCPAppPhysicalCapabilityAdapters
            .ResolveManageSelectionArtifactInputs
    ) async throws -> MCPSelectionConstructionOutcome {
        var snapshot = snapshot
        await MCPToolExecutionHandlerPhaseContext.report(.manageSelectionConstruction)

        snapshot.selection = try await attributed(
            .manageSelectionConstructionVirtualSelectionStabilization
        ) {
            await stabilizedVirtualSelection(snapshot)
        }

        snapshot.selection = physicalize(snapshot.selection)

        let frozenReviewContext: FrozenPromptGitReviewContext?
        let artifactResolution: MCPManageSelectionArtifactResolution

        if artifactAwareOperations.contains(op) {
            let frozen = try await attributed(
                .manageSelectionConstructionGitReviewContextFreeze
            ) {
                await freezePromptGitReviewContext(snapshot)
            }
            frozenReviewContext = frozen

            let identity = snapshot.workspaceID.map {
                WorkspaceSelectionIdentity(
                    workspaceID: $0,
                    tabID: snapshot.tabID
                )
            }

            artifactResolution = try await attributed(
                .manageSelectionConstructionArtifactInputResolution
            ) {
                await resolveManageSelectionArtifactInputs(
                    MCPManageSelectionArtifactResolutionRequest(
                        paths: parsedInputs.paths,
                        sliceInputs: parsedInputs.sliceInputs,
                        use: op == "remove" ? .remove : .insert,
                        mode: mode,
                        physicalSelection: snapshot.selection,
                        identity: identity,
                        capability: frozen.artifactCapability
                    )
                )
            }
        } else {
            frozenReviewContext = nil
            let artifactInputs = parsedInputs.paths.filter {
                let path = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return path == "_git_data" || path.hasPrefix("_git_data/")
            }
            if !artifactInputs.isEmpty, op == "promote" || op == "demote" {
                throw MCPError.invalidParams(
                    "Git artifact aliases support add, remove, set, and preview in mode 'full' only."
                )
            }
            artifactResolution = MCPManageSelectionArtifactResolution(
                ordinaryPaths: parsedInputs.paths,
                ordinarySliceInputs: parsedInputs.sliceInputs,
                artifacts: [],
                invalidDiagnostics: [],
                fence: nil
            )
        }

        return MCPSelectionConstructionOutcome(
            snapshot: snapshot,
            frozenReviewContext: frozenReviewContext,
            artifactResolution: artifactResolution
        )
    }
}
