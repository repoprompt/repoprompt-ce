import Foundation
import RepoPromptCore

enum AgentProviderContextBuilder {
    static func initialFileTree(
        selection logicalSelection: StoredSelection,
        factualProvider: any PromptFactualContextProviding,
        lookupContext: WorkspaceLookupContext,
        admission: WorkspaceSessionAdmissionToken? = nil,
        filePathDisplay: FilePathDisplay = .relative,
        onlyIncludeRootsWithSelectedFiles: Bool = false,
        showCodeMapMarkers: Bool = true
    ) async -> String {
        let request = factualRequest(
            selection: logicalSelection,
            lookupContext: lookupContext,
            filePathDisplay: filePathDisplay,
            codeMapUsage: .none,
            rendersFileTree: true,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            showCodeMapMarkers: showCodeMapMarkers
        )
        guard case let .ready(snapshot) = await factualProvider.capture(
            request,
            admission: admission
        ) else {
            return ""
        }
        return snapshot.rendered.fileTreeContent ?? ""
    }

    static func forkFileContentsBlock(
        selection logicalSelection: StoredSelection,
        tokenCap: Int,
        factualProvider: any PromptFactualContextProviding,
        lookupContext: WorkspaceLookupContext,
        admission: WorkspaceSessionAdmissionToken? = nil,
        overTokenCapSummaryProvider: ((PromptFactualContextSnapshot) async -> String?)? = nil
    ) async -> String {
        let request = factualRequest(
            selection: logicalSelection,
            lookupContext: lookupContext,
            filePathDisplay: .relative,
            codeMapUsage: .auto,
            rendersFileTree: false,
            onlyIncludeRootsWithSelectedFiles: false,
            showCodeMapMarkers: true
        )
        guard case let .ready(snapshot) = await factualProvider.capture(
            request,
            admission: admission
        ) else {
            return ""
        }
        let selectionTokens = snapshot.tokenResult.totalTokenCountFilesOnly
            + snapshot.tokenResult.codeMapTokenCount

        if selectionTokens > tokenCap {
            if let summary = await overTokenCapSummaryProvider?(snapshot),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return summary
            }
            return "<selection_summary>\(snapshot.entries.count) files, ~\(selectionTokens) tokens (contents omitted, exceeds \(tokenCap) token cap)</selection_summary>"
        }

        var sections: [String] = []
        if let fileMap = snapshot.rendered.combinedFileMapContent {
            sections.append("""
            <file_map>
            \(fileMap)
            </file_map>
            """)
        }
        if !snapshot.rendered.contentBlocks.isEmpty {
            sections.append("""
            <file_contents>
            \(snapshot.rendered.contentBlocks.joined(separator: "\n\n"))
            </file_contents>
            """)
        }
        return sections.joined(separator: "\n\n")
    }

    private static func factualRequest(
        selection: StoredSelection,
        lookupContext: WorkspaceLookupContext,
        filePathDisplay: FilePathDisplay,
        codeMapUsage: CodeMapUsage,
        rendersFileTree: Bool,
        onlyIncludeRootsWithSelectedFiles: Bool,
        showCodeMapMarkers: Bool
    ) -> PromptFactualCaptureRequest {
        PromptFactualCaptureRequest(
            selection: selection,
            rootScope: lookupContext.rootScope.excludingWorkspaceGitData,
            projection: lookupContext.bindingProjection?.frozenPromptProjection(),
            filePathDisplay: filePathDisplay,
            codeMapUsage: codeMapUsage,
            entryResolutionProfile: .uiAssisted,
            rendersFileTree: rendersFileTree,
            fileTreeMode: .auto,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            includeFileTreeLegend: true,
            showCodeMapMarkers: showCodeMapMarkers,
            authorizedArtifactBatch: .empty,
            selectedDiffFolderPolicy: .filesOnly,
            selectedDiffLookupProfile: .uiAssisted
        )
    }
}
