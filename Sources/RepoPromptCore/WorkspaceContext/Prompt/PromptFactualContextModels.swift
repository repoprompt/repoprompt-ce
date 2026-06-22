import Foundation

package enum PromptFactualCaptureFailure: Error, Equatable {
    case notReady
    case staleGeneration
    case closedSession
    case missingWorktree
    case invalidFrozenInput
}

package enum PromptSelectedDiffFolderPolicy: Equatable {
    case filesOnly
    case expandFolders
}

package struct PromptSelectedDiffPathResolution: Equatable {
    package let paths: [String]
    package let unresolvedLogicalCandidates: [String]

    package init(paths: [String], unresolvedLogicalCandidates: [String]) {
        self.paths = paths
        self.unresolvedLogicalCandidates = unresolvedLogicalCandidates
    }
}

package struct PromptFactualCaptureRequest: @unchecked Sendable {
    package let selection: StoredSelection
    package let rootScope: WorkspaceLookupRootScope
    package let projection: FrozenWorkspacePathProjection?
    package let filePathDisplay: FilePathDisplay
    package let codeMapUsage: CodeMapUsage
    package let entryResolutionProfile: PathLocateProfile
    package let rendersFileTree: Bool
    package let fileTreeMode: WorkspaceFileTreeSnapshotMode
    package let onlyIncludeRootsWithSelectedFiles: Bool
    package let includeFileTreeLegend: Bool
    package let showCodeMapMarkers: Bool
    package let authorizedArtifactBatch: PromptAuthorizedArtifactBatch
    package let selectedDiffFolderPolicy: PromptSelectedDiffFolderPolicy
    package let selectedDiffLookupProfile: PathLocateProfile
    package let promptText: String
    package let selectedInstructionsText: String
    package let duplicateUserInstructionsAtTop: Bool

    package init(
        selection: StoredSelection,
        rootScope: WorkspaceLookupRootScope,
        projection: FrozenWorkspacePathProjection?,
        filePathDisplay: FilePathDisplay,
        codeMapUsage: CodeMapUsage,
        entryResolutionProfile: PathLocateProfile,
        rendersFileTree: Bool,
        fileTreeMode: WorkspaceFileTreeSnapshotMode,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeFileTreeLegend: Bool,
        showCodeMapMarkers: Bool,
        authorizedArtifactBatch: PromptAuthorizedArtifactBatch,
        selectedDiffFolderPolicy: PromptSelectedDiffFolderPolicy,
        selectedDiffLookupProfile: PathLocateProfile,
        promptText: String = "",
        selectedInstructionsText: String = "",
        duplicateUserInstructionsAtTop: Bool = false
    ) {
        self.selection = selection
        self.rootScope = rootScope
        self.projection = projection
        self.filePathDisplay = filePathDisplay
        self.codeMapUsage = codeMapUsage
        self.entryResolutionProfile = entryResolutionProfile
        self.rendersFileTree = rendersFileTree
        self.fileTreeMode = fileTreeMode
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeFileTreeLegend = includeFileTreeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.authorizedArtifactBatch = authorizedArtifactBatch
        self.selectedDiffFolderPolicy = selectedDiffFolderPolicy
        self.selectedDiffLookupProfile = selectedDiffLookupProfile
        self.promptText = promptText
        self.selectedInstructionsText = selectedInstructionsText
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
    }
}

package struct PromptFactualRenderedSections: Equatable {
    package let fileTreeContent: String?
    package let codemapBlocks: [String]
    package let contentBlocks: [String]
    package let selectedPatchText: String?

    package init(
        fileTreeContent: String?,
        codemapBlocks: [String],
        contentBlocks: [String],
        selectedPatchText: String?
    ) {
        self.fileTreeContent = fileTreeContent
        self.codemapBlocks = codemapBlocks
        self.contentBlocks = contentBlocks
        self.selectedPatchText = selectedPatchText
    }

    package var combinedFileMapContent: String? {
        let codemaps = codemapBlocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let combined = [fileTreeContent ?? "", codemaps].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }
}

package struct PromptFactualEntrySummary: Equatable {
    package let fileID: UUID
    package let logicalDisplayPath: String
    package let fileName: String
    package let fileExtension: String?
    package let isCodemap: Bool

    package init(
        fileID: UUID,
        logicalDisplayPath: String,
        fileName: String,
        fileExtension: String?,
        isCodemap: Bool
    ) {
        self.fileID = fileID
        self.logicalDisplayPath = logicalDisplayPath
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.isCodemap = isCodemap
    }
}

package struct PromptFactualContextSnapshot: @unchecked Sendable {
    package let catalogGeneration: UInt64
    package let fileTreeRootCount: Int
    package let rendered: PromptFactualRenderedSections
    package let tokenResult: TokenCalculationResult
    package let entries: [PromptFactualEntrySummary]
    package let missingLogicalPaths: [String]
    package let invalidLogicalPaths: [String]
    package let selectedDiffPathResolution: PromptSelectedDiffPathResolution
    package let artifactDispositions: [PromptAuthorizedArtifactDisposition]

    package init(
        catalogGeneration: UInt64,
        fileTreeRootCount: Int,
        rendered: PromptFactualRenderedSections,
        tokenResult: TokenCalculationResult,
        entries: [PromptFactualEntrySummary],
        missingLogicalPaths: [String],
        invalidLogicalPaths: [String],
        selectedDiffPathResolution: PromptSelectedDiffPathResolution,
        artifactDispositions: [PromptAuthorizedArtifactDisposition]
    ) {
        self.catalogGeneration = catalogGeneration
        self.fileTreeRootCount = fileTreeRootCount
        self.rendered = rendered
        self.tokenResult = tokenResult
        self.entries = entries
        self.missingLogicalPaths = missingLogicalPaths
        self.invalidLogicalPaths = invalidLogicalPaths
        self.selectedDiffPathResolution = selectedDiffPathResolution
        self.artifactDispositions = artifactDispositions
    }
}

package enum PromptFactualCaptureOutcome: @unchecked Sendable {
    case ready(PromptFactualContextSnapshot)
    case unavailable(PromptFactualCaptureFailure)
    case cancelled
}
