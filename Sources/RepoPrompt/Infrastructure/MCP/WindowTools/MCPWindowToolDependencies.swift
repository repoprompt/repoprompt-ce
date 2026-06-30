import Foundation
import MCP

/// Constructor-time dependency bundle for extracted window-tool providers.
///
/// Providers receive narrow services/closures instead of an
/// `MCPServerViewModel` reference.
struct MCPWindowToolDependencies {
    struct ContextBuilderTabResolution {
        let tabID: UUID
        let workspaceID: UUID?
        let agentModeSessionID: UUID?
        let agentModeRunID: UUID?
        let bindCaller: Bool
        let lookupContext: WorkspaceLookupContext
        let workspaceContext: ContextBuilderWorkspaceContext?
        let reviewGitContext: FrozenPromptGitReviewContext
    }

    typealias ExecuteTool = @Sendable (_ args: [String: Value]) async throws -> Value
    typealias WorkspaceSearch = @Sendable (
        _ pattern: String,
        _ mode: SearchMode,
        _ isRegex: Bool,
        _ caseInsensitive: Bool,
        _ maxPaths: Int,
        _ maxMatches: Int,
        _ paths: [String]?,
        _ includeExtensions: [String],
        _ excludePatterns: [String],
        _ contextLines: Int,
        _ wholeWord: Bool,
        _ countOnly: Bool,
        _ fuzzySpaceMatching: Bool,
        _ rootScope: WorkspaceLookupRootScope
    ) async throws -> SearchResults
    typealias RequireTargetWindow = @MainActor @Sendable () throws -> WindowState
    typealias RequireCurrentTabContext = @MainActor @Sendable (_ toolName: String) async throws -> MCPServerViewModel.TabScopedContext
    typealias RequireAgentModeConnection = @Sendable (_ toolName: String) async throws -> UUID
    typealias ResolveAgentModeTabID = @Sendable (_ args: [String: Value], _ connectionID: UUID?) async throws -> UUID
    typealias ResolveContextBuilderTab = @MainActor @Sendable (
        _ args: [String: Value],
        _ targetWindow: WindowState,
        _ connectionID: UUID?
    ) async throws -> ContextBuilderTabResolution
    typealias BindTabForConnection = @MainActor @Sendable (
        _ connectionID: UUID,
        _ clientName: String?,
        _ tabID: UUID,
        _ workspaceID: UUID,
        _ windowID: Int
    ) throws -> Void
    typealias BuildTabSelectionReply = @MainActor @Sendable (
        _ selection: StoredSelection,
        _ includeBlocks: Bool,
        _ display: FilePathDisplay,
        _ codeMapUsageOverride: CodeMapUsage?,
        _ lookupContextOverride: WorkspaceLookupContext?,
        _ reviewGitContextOverride: FrozenPromptGitReviewContext?
    ) async throws -> ToolResultDTOs.SelectionReply
    typealias SendStageProgress = @Sendable (
        _ connectionID: UUID?,
        _ tool: String,
        _ stage: String,
        _ message: String
    ) async -> Void
    typealias MakeOracleExportDestination = @MainActor @Sendable (
        _ workspace: WorkspaceModel?,
        _ windowID: Int,
        _ tabID: UUID?,
        _ lookupContext: WorkspaceLookupContext
    ) throws -> OracleExportDestination
    typealias ResolveDefaultOracleExportPath = @MainActor @Sendable (
        _ mode: String,
        _ chatID: String?,
        _ destination: OracleExportDestination
    ) throws -> String
    typealias WriteGeneratedOracleExportFile = @Sendable (
        _ path: String,
        _ content: String,
        _ destination: OracleExportDestination
    ) async throws -> String
    typealias BeforeContextBuilderFinalReviewAuthorization = @MainActor @Sendable () async -> Void
    typealias DidFinalizeContextBuilderReview = @MainActor @Sendable (
        _ authorization: ContextBuilderFinalReviewAuthorization
    ) async -> Void
    typealias RunMCPPlanOrQuestion = @MainActor @Sendable (
        _ contextBuilderVM: ContextBuilderAgentViewModel,
        _ tabID: UUID,
        _ agentModeSessionID: UUID?,
        _ agentModeRunID: UUID?,
        _ mode: HeadlessMode,
        _ prompt: String,
        _ selection: StoredSelection,
        _ lookupContext: WorkspaceLookupContext?,
        _ reviewGitContext: FrozenPromptGitReviewContext,
        _ finalReviewAuthorization: ContextBuilderFinalReviewAuthorization?,
        _ progressReporter: ContextBuilderMCPProgressReporter?,
        _ activityReporter: ContextBuilderMCPActivityReporter?
    ) async throws -> ChatSendReply
    typealias CaptureRequestMetadata = @MainActor @Sendable () async -> MCPServerViewModel.RequestMetadata
    typealias ResolveImplicitContextBuilderGitTarget = @MainActor @Sendable (
        _ metadata: MCPServerViewModel.RequestMetadata
    ) async throws -> ContextBuilderReviewTargetResolution?
    typealias ValidateContextBuilderGitArtifactSelection = @MainActor @Sendable (
        _ metadata: MCPServerViewModel.RequestMetadata,
        _ target: ContextBuilderReviewTarget
    ) async throws -> Void
    typealias ResolveTabContextSnapshot = @MainActor @Sendable (
        _ metadata: MCPServerViewModel.RequestMetadata,
        _ toolName: String,
        _ policy: MCPServerViewModel.TabContextResolutionPolicy
    ) throws -> MCPServerViewModel.ResolvedTabContextSnapshot
    typealias UpdateCurrentTabContext = @MainActor @Sendable (
        _ toolName: String,
        _ mutation: (inout MCPServerViewModel.TabScopedContext) -> Void
    ) async throws -> Void
    typealias SelectedRecordsForCurrentTabContext = @MainActor @Sendable (
        _ metadata: MCPServerViewModel.RequestMetadata,
        _ lookupContextOverride: WorkspaceLookupContext?
    ) async throws -> [WorkspaceFileRecord]
    typealias PhysicalSelectionForCurrentTabContext = @MainActor @Sendable (
        _ metadata: MCPServerViewModel.RequestMetadata,
        _ lookupContextOverride: WorkspaceLookupContext?
    ) async throws -> StoredSelection
    typealias ResolveSelectedFilesForCodeStructure = @MainActor @Sendable (
        _ metadata: MCPServerViewModel.RequestMetadata,
        _ lookupContext: WorkspaceLookupContext,
        _ maximumSeedCount: Int
    ) async throws -> [WorkspaceFileRecord]
    typealias BoundTabID = @MainActor @Sendable (_ connectionID: UUID?) -> UUID?
    typealias MapFileManagerErrorToMCP = @MainActor @Sendable (_ error: FileManagerError, _ action: String, _ path: String?) async -> MCPError
    typealias EnsureGitDataRootLoaded = @MainActor @Sendable (
        _ workspace: WorkspaceModel,
        _ workspaceManager: WorkspaceManagerViewModel
    ) async throws -> WorkspaceRootRef
    typealias DebugLog = @Sendable (_ message: String) -> Void
    typealias CommitPrimaryGitDiffArtifactsToCurrentTab = @MainActor @Sendable (
        _ toolName: String,
        _ candidates: [GitDiffPublishedArtifact],
        _ sourceSelection: StoredSelection?
    ) async throws -> MCPServerViewModel.PrimaryGitArtifactCommitResult
    typealias ReplaceAdvertisedGitArtifactsForCurrentTab = @MainActor @Sendable (
        _ toolName: String,
        _ artifacts: [GitDiffPublishedArtifact]
    ) async throws -> MCPGitArtifactAdvertisementSnapshot
    typealias InvalidateAdvertisedGitArtifactsForCurrentTab = @MainActor @Sendable (
        _ toolName: String
    ) async -> Void
    typealias FreezePromptGitReviewContext = @MainActor @Sendable (
        _ context: MCPServerViewModel.TabScopedContext
    ) async -> FrozenPromptGitReviewContext
    typealias ParseManageSelectionInputs = @Sendable (_ rawPaths: [String], _ slicesValue: Value?) -> MCPServerViewModel.ManageSelectionInputs
    typealias ResolveFileToolLookupContext = @MainActor @Sendable (_ metadata: MCPServerViewModel.RequestMetadata) async -> WorkspaceLookupContext
    typealias StabilizedVirtualSelection = @MainActor @Sendable (_ context: MCPServerViewModel.TabScopedContext) async -> StoredSelection
    typealias BuildCurrentSelectionReply = @MainActor @Sendable (
        _ includeBlocks: Bool,
        _ display: FilePathDisplay,
        _ extraInvalid: [String],
        _ viewMode: String?,
        _ resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot,
        _ lookupContext: WorkspaceLookupContext
    ) async throws -> ToolResultDTOs.SelectionReply
    typealias BuildSelectionPreviewReply = @MainActor @Sendable (
        _ selection: StoredSelection,
        _ includeBlocks: Bool,
        _ display: FilePathDisplay,
        _ extraInvalid: [String],
        _ viewMode: String?,
        _ codeMapUsageOverride: CodeMapUsage?,
        _ lookupContext: WorkspaceLookupContext,
        _ virtualContext: MCPServerViewModel.TabScopedContext?,
        _ reviewGitContext: FrozenPromptGitReviewContext?
    ) async throws -> ToolResultDTOs.SelectionReply
    typealias BuildSelectionMutationReply = @MainActor @Sendable (
        _ selection: StoredSelection,
        _ includeBlocks: Bool,
        _ display: FilePathDisplay,
        _ extraInvalid: [String],
        _ viewMode: String?,
        _ codeMapUsageOverride: CodeMapUsage?,
        _ virtualContext: MCPServerViewModel.TabScopedContext?,
        _ lookupContext: WorkspaceLookupContext,
        _ reviewGitContext: FrozenPromptGitReviewContext?
    ) async throws -> ToolResultDTOs.SelectionReply
    typealias BuildManageSelectionSetSelection = @MainActor @Sendable (
        _ inputs: MCPServerViewModel.ManageSelectionInputs,
        _ mode: String,
        _ existing: StoredSelection,
        _ hasFullFileArtifactInputs: Bool,
        _ lookupRootScope: WorkspaceLookupRootScope
    ) async -> MCPServerViewModel.BuildStoredSelectionResult
    typealias ResolveManageSelectionArtifactInputs = @MainActor @Sendable (
        _ request: MCPManageSelectionArtifactResolutionRequest
    ) async -> MCPManageSelectionArtifactResolution
    typealias ValidateManageSelectionArtifactFence = @MainActor @Sendable (
        _ fence: MCPManageSelectionArtifactAuthorizationFence
    ) async -> Bool
    typealias MutatePreResolvedFullFilePaths = @MainActor @Sendable (
        _ base: StoredSelection,
        _ absolutePaths: [String],
        _ mode: WorkspacePreResolvedFullFileMutationMode
    ) -> StoredSelection
    typealias CommitManageSelectionArtifactMutation = @MainActor @Sendable (
        _ resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot,
        _ metadata: MCPServerViewModel.RequestMetadata,
        _ expectedPhysicalSelection: StoredSelection,
        _ requestedPhysicalSelection: StoredSelection,
        _ lookupContext: WorkspaceLookupContext,
        _ fence: MCPManageSelectionArtifactAuthorizationFence
    ) async -> MCPServerViewModel.MCPManageSelectionArtifactCommitResult
    typealias AddStoredSelectionPaths = @MainActor @Sendable (
        _ existing: StoredSelection,
        _ paths: [String],
        _ rawPaths: [String],
        _ mode: String,
        _ lookupRootScope: WorkspaceLookupRootScope
    ) async -> MCPServerViewModel.AddStoredSelectionResult
    typealias RemoveStoredSelectionPaths = @MainActor @Sendable (
        _ existing: StoredSelection,
        _ paths: [String],
        _ rawPaths: [String],
        _ mode: String,
        _ lookupRootScope: WorkspaceLookupRootScope
    ) async -> (StoredSelection, [String], [String: String], Bool)
    typealias PromoteStoredSelectionPaths = @MainActor @Sendable (
        _ existing: StoredSelection,
        _ paths: [String],
        _ rawPaths: [String],
        _ strict: Bool,
        _ lookupRootScope: WorkspaceLookupRootScope
    ) async -> (StoredSelection, [String], Bool)
    typealias DemoteStoredSelectionPaths = @MainActor @Sendable (
        _ existing: StoredSelection,
        _ paths: [String],
        _ rawPaths: [String],
        _ strict: Bool,
        _ lookupRootScope: WorkspaceLookupRootScope
    ) async -> MCPServerViewModel.DemoteStoredSelectionResult
    typealias ComputeSelectionSlicesVirtual = @MainActor @Sendable (
        _ base: StoredSelection,
        _ entries: [WorkspaceSelectionSliceInput],
        _ mode: SliceMutationMode,
        _ lookupRootScope: WorkspaceLookupRootScope
    ) async -> (selection: StoredSelection, result: MCPServerViewModel.MCPSelectionSlicesMutationResult, mutated: Bool)
    typealias PersistResolvedTabContextSnapshot = @MainActor @Sendable (
        _ resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot,
        _ metadata: MCPServerViewModel.RequestMetadata,
        _ mutated: Bool
    ) async -> MCPServerViewModel.MCPSelectionPersistenceVerification?
    typealias MakeSelectionHintError = @MainActor @Sendable (_ paths: [String], _ operation: String, _ lookupContext: WorkspaceLookupContext) async -> String
    typealias PerformFileAction = @MainActor @Sendable (_ action: String, _ path: String, _ content: String?, _ newPath: String?, _ ifExists: String?) async throws -> String?
    typealias BuildCodeStructureDTO = @MainActor @Sendable (_ files: [WorkspaceFileRecord], _ request: MCPServerViewModel.CodeStructureRequest, _ includePathNotFoundIssue: Bool, _ lookupContext: WorkspaceLookupContext) async throws -> ToolResultDTOs.CodeStructureReplyDTO
    typealias ResolveFilesForCodeStructure = @MainActor @Sendable (_ paths: [String], _ lookupRootScope: WorkspaceLookupRootScope, _ maximumSeedCount: Int) async throws -> [WorkspaceFileRecord]
    typealias BuildStoreBackedFileTreeResult = @MainActor @Sendable (_ mode: String, _ maxDepth: Int?, _ startPath: String?, _ lookupContext: WorkspaceLookupContext) async throws -> (result: FileTreeResult, rootCount: Int)
    typealias ReadFile = @MainActor @Sendable (_ path: String, _ startLine1Based: Int?, _ lineCount: Int?, _ lookupRootScope: WorkspaceLookupRootScope) async throws -> (reply: ToolResultDTOs.ReadFileReply, shouldAutoSelect: Bool)
    typealias ReadSelectedAuthorizedGitArtifact = @MainActor @Sendable (
        _ requestedPath: String,
        _ resolvedPath: String,
        _ startLine1Based: Int?,
        _ lineCount: Int?,
        _ metadata: MCPServerViewModel.RequestMetadata,
        _ lookupContext: WorkspaceLookupContext
    ) async throws -> (reply: ToolResultDTOs.ReadFileReply, shouldAutoSelect: Bool)?
    typealias EnqueueReadFileAutoSelection = @MainActor @Sendable (
        _ reply: ToolResultDTOs.ReadFileReply,
        _ requestedPath: String,
        _ resolvedPhysicalPath: String,
        _ metadata: MCPServerViewModel.RequestMetadata
    ) async -> Void
    typealias DrainReadFileAutoSelection = @MainActor @Sendable (_ metadata: MCPServerViewModel.RequestMetadata, _ requirement: MCPReadFileAutoSelectionCoordinator.DrainRequirement) async -> MCPReadFileAutoSelectionCoordinator.DrainResult
    typealias EnqueueFileSearchAutoSelection = @MainActor @Sendable (
        _ mode: SearchMode,
        _ contextLines: Int,
        _ reply: ToolResultDTOs.SearchResultDTO,
        _ resolvedPhysicalPaths: [String],
        _ metadata: MCPServerViewModel.RequestMetadata
    ) async -> Void
    typealias WorkspaceContextMessage = @MainActor @Sendable (_ operation: String?, _ path: String?) async -> String
    typealias ParseCopyPresetSelector = @Sendable (_ value: Value?) -> MCPServerViewModel.CopyPresetSelector?
    typealias ResolveCopyPreset = @MainActor @Sendable (_ selector: MCPServerViewModel.CopyPresetSelector) -> CopyPreset?
    typealias BuildTabWorkspaceContext = @MainActor @Sendable (_ context: MCPServerViewModel.TabScopedContext, _ include: Set<String>, _ display: FilePathDisplay, _ copyPresetOverride: CopyPreset?, _ activeTabCompatibility: Bool) async throws -> ToolResultDTOs.PromptContextDTO
    typealias SelectedFilesWithStats = @MainActor @Sendable (_ resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot) async throws -> ToolResultDTOs.SelectedFilesReply
    typealias SelectionCollectionsForCurrentTabContext = @MainActor @Sendable () async throws -> MCPServerViewModel.SelectionReplyAssembler.SelectionCollections
    typealias BuildCopyPresetContextDTO = @MainActor @Sendable (_ active: CopyPreset, _ effective: CopyPreset) -> ToolResultDTOs.CopyPresetContextDTO
    typealias BuildCopyPresetsListDTO = @MainActor @Sendable () -> [ToolResultDTOs.CopyPresetListItemDTO]
    typealias CopyPresetDescriptorDTO = @MainActor @Sendable (_ preset: CopyPreset) -> ToolResultDTOs.CopyPresetDescriptorDTO
    typealias BuildExportSelectedFileInfos = @MainActor @Sendable (
        _ resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot?,
        _ cfg: PromptContextResolved,
        _ selectionOverride: StoredSelection?,
        _ display: FilePathDisplay
    ) async throws -> [ToolResultDTOs.SelectedFileInfo]
    typealias BuildTabClipboardContent = @MainActor @Sendable (_ cfg: PromptContextResolved, _ context: MCPServerViewModel.TabScopedContext) async -> String
    typealias WritePromptExportFile = @MainActor @Sendable (_ path: String, _ content: String) async throws -> String
    typealias LatestTokenBreakdown = @MainActor @Sendable () -> TokenCountingViewModel.TokenBreakdown

    let executeOracleUtils: ExecuteTool
    let executeAskOracle: ExecuteTool
    let executeOracleSend: ExecuteTool
    let executeOracleChatLog: ExecuteTool

    let executeAgentExplore: ExecuteTool
    let executeAgentRun: ExecuteTool
    let executeAgentManage: ExecuteTool

    let requireTargetWindow: RequireTargetWindow
    let requireCurrentTabContext: RequireCurrentTabContext
    let requireAgentModeConnection: RequireAgentModeConnection
    let resolveAgentModeTabID: ResolveAgentModeTabID
    let resolveContextBuilderTab: ResolveContextBuilderTab
    let bindTabForConnection: BindTabForConnection
    let buildTabSelectionReply: BuildTabSelectionReply
    let sendStageProgress: SendStageProgress
    let makeOracleExportDestination: MakeOracleExportDestination
    let resolveDefaultOracleExportPath: ResolveDefaultOracleExportPath
    let writeGeneratedOracleExportFile: WriteGeneratedOracleExportFile
    let beforeContextBuilderFinalReviewAuthorization: BeforeContextBuilderFinalReviewAuthorization
    let didFinalizeContextBuilderReview: DidFinalizeContextBuilderReview
    let runMCPPlanOrQuestion: RunMCPPlanOrQuestion

    let windowID: Int
    let promptVM: PromptViewModel
    let workspaceManager: WorkspaceManagerViewModel?
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let applyEditsApprovalStore: ApplyEditsApprovalStore
    let captureRequestMetadata: CaptureRequestMetadata
    let resolveImplicitContextBuilderGitTarget: ResolveImplicitContextBuilderGitTarget
    let validateContextBuilderGitArtifactSelection: ValidateContextBuilderGitArtifactSelection
    let resolveTabContextSnapshot: ResolveTabContextSnapshot
    let updateCurrentTabContext: UpdateCurrentTabContext
    let selectedRecordsForCurrentTabContext: SelectedRecordsForCurrentTabContext
    let physicalSelectionForCurrentTabContext: PhysicalSelectionForCurrentTabContext
    let resolveSelectedFilesForCodeStructure: ResolveSelectedFilesForCodeStructure
    let boundTabID: BoundTabID
    let mapFileManagerErrorToMCP: MapFileManagerErrorToMCP
    let ensureGitDataRootLoaded: EnsureGitDataRootLoaded
    let logDebug: DebugLog
    let commitPrimaryGitDiffArtifactsToCurrentTab: CommitPrimaryGitDiffArtifactsToCurrentTab
    let replaceAdvertisedGitArtifactsForCurrentTab: ReplaceAdvertisedGitArtifactsForCurrentTab
    let invalidateAdvertisedGitArtifactsForCurrentTab: InvalidateAdvertisedGitArtifactsForCurrentTab

    let workspaceSearch: WorkspaceSearch
    let parseManageSelectionInputs: ParseManageSelectionInputs
    let resolveFileToolLookupContext: ResolveFileToolLookupContext
    let stabilizedVirtualSelection: StabilizedVirtualSelection
    let freezePromptGitReviewContext: FreezePromptGitReviewContext
    let buildCurrentSelectionReply: BuildCurrentSelectionReply
    let buildSelectionPreviewReply: BuildSelectionPreviewReply
    let buildSelectionMutationReply: BuildSelectionMutationReply
    let buildManageSelectionSetSelection: BuildManageSelectionSetSelection
    let resolveManageSelectionArtifactInputs: ResolveManageSelectionArtifactInputs
    let validateManageSelectionArtifactFence: ValidateManageSelectionArtifactFence
    let mutatePreResolvedFullFilePaths: MutatePreResolvedFullFilePaths
    let commitManageSelectionArtifactMutation: CommitManageSelectionArtifactMutation
    let addStoredSelectionPaths: AddStoredSelectionPaths
    let removeStoredSelectionPaths: RemoveStoredSelectionPaths
    let promoteStoredSelectionPaths: PromoteStoredSelectionPaths
    let demoteStoredSelectionPaths: DemoteStoredSelectionPaths
    let computeSelectionSlicesVirtual: ComputeSelectionSlicesVirtual
    let persistResolvedTabContextSnapshot: PersistResolvedTabContextSnapshot
    let makeSelectionHintError: MakeSelectionHintError

    let performFileAction: PerformFileAction
    let buildCodeStructureDTO: BuildCodeStructureDTO
    let resolveFilesForCodeStructure: ResolveFilesForCodeStructure
    let buildStoreBackedFileTreeResult: BuildStoreBackedFileTreeResult
    let readSelectedAuthorizedGitArtifact: ReadSelectedAuthorizedGitArtifact
    let readFile: ReadFile
    let enqueueReadFileAutoSelection: EnqueueReadFileAutoSelection
    let drainReadFileAutoSelection: DrainReadFileAutoSelection
    let enqueueFileSearchAutoSelection: EnqueueFileSearchAutoSelection
    let workspaceContextMessage: WorkspaceContextMessage

    let parseCopyPresetSelector: ParseCopyPresetSelector
    let resolveCopyPreset: ResolveCopyPreset
    let buildTabWorkspaceContext: BuildTabWorkspaceContext
    let selectedFilesWithStats: SelectedFilesWithStats
    let selectionCollectionsForCurrentTabContext: SelectionCollectionsForCurrentTabContext
    let buildCopyPresetContextDTO: BuildCopyPresetContextDTO
    let buildCopyPresetsListDTO: BuildCopyPresetsListDTO
    let copyPresetDescriptorDTO: CopyPresetDescriptorDTO
    let buildExportSelectedFileInfos: BuildExportSelectedFileInfos
    let buildTabClipboardContent: BuildTabClipboardContent
    let writePromptExportFile: WritePromptExportFile
    let latestTokenBreakdown: LatestTokenBreakdown
}
