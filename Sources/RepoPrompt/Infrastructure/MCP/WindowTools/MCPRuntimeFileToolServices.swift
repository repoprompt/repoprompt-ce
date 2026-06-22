import Foundation
import MCP
import RepoPromptCore

enum MCPRuntimeFileToolServices {
    static func resolveCodeStructureFiles(
        paths: [String],
        context: MCPRuntimeFileToolContext
    ) async throws -> [WorkspaceFileRecord] {
        var catalogFiles: [WorkspaceFileRecord] = []
        if case let .available(snapshot) = await context.query.searchCatalogAccess(
            rootScope: context.lookupContext.rootScope,
            requirement: .recordsOnly
        ) {
            catalogFiles = snapshot.files
        }

        var result: [WorkspaceFileRecord] = []
        var seen = Set<String>()
        for path in paths {
            try Task.checkCancellation()
            guard let lookup = await context.query.lookupPath(WorkspacePathLookupRequest(
                userPath: path,
                profile: .mcpRead,
                rootScope: context.lookupContext.rootScope
            )) else { continue }
            if let file = lookup.file, seen.insert(file.standardizedFullPath).inserted {
                result.append(file)
                continue
            }
            guard let folder = lookup.folder else { continue }
            let prefix = folder.standardizedRelativePath.isEmpty
                ? ""
                : folder.standardizedRelativePath + "/"
            for file in catalogFiles where file.rootID == folder.rootID
                && (prefix.isEmpty || file.standardizedRelativePath.hasPrefix(prefix))
                && seen.insert(file.standardizedFullPath).inserted
            {
                result.append(file)
            }
        }
        return result
    }

    static func buildCodeStructureDTO(
        files: [WorkspaceFileRecord],
        maxResults: Int,
        includeUnmappedPaths: Bool,
        context: MCPRuntimeFileToolContext
    ) async throws -> ToolResultDTOs.SelectedCodeStructureDTO {
        let roots = await context.query.rootRefs(scope: context.lookupContext.rootScope)
        let rootIDs = Set(roots.map(\.id))
        let codemaps = await context.query.codemapSnapshotBundle(rootScope: context.lookupContext.rootScope)
        var entries: [(key: String, display: String, api: FileAPI?)] = []
        var seen = Set<String>()
        for file in files where rootIDs.contains(file.rootID) && seen.insert(file.standardizedFullPath).inserted {
            let display = context.lookupContext.bindingProjection?.projectedLogicalDisplayPath(
                forPhysicalPath: file.standardizedFullPath,
                display: .relative
            ) ?? roots.first(where: { $0.id == file.rootID }).map {
                ClientPathFormatter.displayPath(root: $0, relativePath: file.standardizedRelativePath, visibleRoots: roots)
            } ?? file.relativePath
            entries.append((file.standardizedFullPath, display, codemaps.snapshot(for: file)?.fileAPI))
        }
        entries.sort { $0.display == $1.display ? $0.key < $1.key : $0.display < $1.display }

        let cap = max(0, maxResults)
        let mapped = entries.filter { $0.api != nil }
        var content: [String] = []
        var estimatedTokens = 0
        var tokenOmitted = 0
        for entry in mapped.prefix(cap) {
            guard let api = entry.api else { continue }
            let estimate = api.estimatedFullAPIDescriptionTokens(displayPath: entry.display)
            if estimatedTokens + estimate > 6000, !content.isEmpty {
                tokenOmitted += 1
                continue
            }
            content.append(api.getFullAPIDescription(displayPath: entry.display))
            estimatedTokens += estimate
        }
        let maxOmitted = max(0, mapped.count - cap)
        let unmapped = includeUnmappedPaths
            ? entries.filter { $0.api == nil }.map(\.display).sorted()
            : []
        return ToolResultDTOs.SelectedCodeStructureDTO(
            fileCount: content.count,
            content: content.joined(separator: "\n\n"),
            unmappedPaths: unmapped.isEmpty ? nil : unmapped,
            pendingPaths: nil,
            omittedCount: maxOmitted > 0 ? maxOmitted : nil,
            omittedTotal: maxOmitted + tokenOmitted > 0 ? maxOmitted + tokenOmitted : nil,
            tokenBudgetOmittedCount: tokenOmitted > 0 ? tokenOmitted : nil,
            tokenBudgetHit: tokenOmitted > 0 ? true : nil,
            worktreeScope: ToolResultDTOs.WorktreeScopeDTO.sessionBound(
                from: context.lookupContext.bindingProjection
            )
        )
    }

    static func fileTree(
        type: String,
        mode: String,
        maxDepth: Int?,
        startPath: String?,
        context: MCPRuntimeFileToolContext
    ) async throws -> ToolResultDTOs.FileTreeDTO {
        let snapshotMode: WorkspaceFileTreeSnapshotMode = switch mode.lowercased() {
        case "full": .full
        case "folders": .folders
        case "auto": .auto
        default: throw MCPError.invalidParams("invalid mode: \(mode)")
        }
        await context.query.awaitAppliedIngress(rootScope: context.lookupContext.rootScope)
        let snapshot = await context.query.makeFileTreeSelectionSnapshot(
            selection: StoredSelection(),
            request: WorkspaceFileTreeSnapshotRequest(
                mode: snapshotMode,
                filePathDisplay: context.filePathDisplay,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: false,
                showCodeMapMarkers: context.codeMapsEnabled,
                rootScope: context.lookupContext.rootScope,
                startPath: startPath.map(context.lookupContext.translateInputPath),
                maxDepth: maxDepth
            ),
            profile: .mcpRead
        )
        let logical = context.lookupContext.bindingProjection?.logicalizeFileTreeSnapshot(snapshot) ?? snapshot
        let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: context.lookupContext.bindingProjection)
        if type == "roots" {
            let lines = logical.roots.map(\.fullPath)
            return ToolResultDTOs.FileTreeDTO(
                rootsCount: logical.roots.count,
                usesLegend: false,
                tree: lines.isEmpty ? "No workspace loaded" : lines.joined(separator: "\n"),
                note: lines.isEmpty ? "No workspace loaded" : nil,
                wasTruncated: false,
                worktreeScope: worktreeScope
            )
        }
        let tree = await Task.detached(priority: .userInitiated) {
            CodeMapExtractor.generateFileTree(using: logical)
        }.value
        return ToolResultDTOs.FileTreeDTO(
            rootsCount: logical.roots.count,
            usesLegend: false,
            tree: tree.isEmpty ? "No workspace loaded" : tree,
            note: tree.isEmpty ? "No workspace loaded" : nil,
            wasTruncated: false,
            worktreeScope: worktreeScope
        )
    }
}
