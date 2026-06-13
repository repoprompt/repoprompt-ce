import Foundation

/// Pure, Sendable projection for the unified Git MCP provider.
enum MCPGitToolProjection {
    typealias Reply = ToolResultDTOs.GitToolReplyDTO

    struct ArtifactProjection {
        let diff: Reply.DiffDTO
        let artifacts: Reply.ArtifactsDTO
        let summary: Reply.SummaryDTO
        let oneliner: String
        let inputs: Reply.DiffInputsDTO
        let modeDetails: String
        let inline: Reply.InlineDTO?
        let emptyReason: String?
        let primaryArtifactCandidates: [String]
    }

    @MainActor
    static func makeLogDTO(_ commits: [VCSCommitSummary]) async throws -> Reply.LogDTO {
        try await MCPProviderProjectionWorker.run(toolName: MCPWindowToolName.git, phase: "log_dto") {
            let state = EditFlowPerf.begin(EditFlowPerf.Stage.Git.dtoConstruction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.Git.dtoConstruction, state) }
            return Reply.LogDTO(commits: commits.map { commit in
                Reply.CommitSummaryDTO(
                    sha: commit.id,
                    shortSha: commit.shortID,
                    author: commit.author,
                    date: commit.dateISO,
                    message: commit.message,
                    filesChanged: commit.filesChanged,
                    insertions: commit.insertions,
                    deletions: commit.deletions
                )
            })
        }
    }

    @MainActor
    static func makeShowDTO(
        commitInfo: VCSCommitInfo,
        changedFiles: [VCSUncommittedFile],
        detail: String,
        diffText: String?
    ) async throws -> Reply.ShowDTO {
        try await MCPProviderProjectionWorker.run(toolName: MCPWindowToolName.git, phase: "show_projection") {
            let dtoState = EditFlowPerf.begin(EditFlowPerf.Stage.Git.dtoConstruction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.Git.dtoConstruction, dtoState) }

            let totals = totals(from: changedFiles)
            var files: [Reply.DiffFileDTO]?
            if detail == "files" || detail == "full" {
                files = diffFileDTOsWithoutHunks(from: changedFiles)
            }
            if detail == "full", let diffText {
                let perFilePatches = GitService.splitUnifiedDiffByFile(diffText)
                files = filesWithParsedHunks(
                    changedFiles: changedFiles,
                    perFilePatches: perFilePatches,
                    nilWhenEmpty: true
                )
            }
            return Reply.ShowDTO(
                sha: commitInfo.id,
                shortSha: commitInfo.shortID,
                author: commitInfo.author,
                date: commitInfo.dateISO,
                message: commitInfo.message,
                files: files,
                totals: totals,
                hunks: nil
            )
        }
    }

    @MainActor
    static func makeBlameDTO(path: String, lines: [VCSBlameLine]) async throws -> Reply.BlameDTO {
        try await MCPProviderProjectionWorker.run(toolName: MCPWindowToolName.git, phase: "blame_dto") {
            let state = EditFlowPerf.begin(EditFlowPerf.Stage.Git.dtoConstruction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.Git.dtoConstruction, state) }
            return Reply.BlameDTO(
                path: path,
                lines: lines.map { line in
                    Reply.BlameLineDTO(
                        num: line.line,
                        sha: line.id,
                        author: line.author,
                        date: line.dateISO,
                        content: line.content
                    )
                }
            )
        }
    }

    @MainActor
    static func makeDiffDTO(
        compare: String,
        detail: String,
        changedFiles: [VCSUncommittedFile],
        perFilePatches: [String: String]?,
        maxLinesForPatches: Int
    ) async throws -> Reply.DiffDTO {
        try await MCPProviderProjectionWorker.run(toolName: MCPWindowToolName.git, phase: "diff_projection") {
            let dtoState = EditFlowPerf.begin(EditFlowPerf.Stage.Git.dtoConstruction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.Git.dtoConstruction, dtoState) }

            let includesHunks = detail == "patches" || detail == "full"
            let totals = totals(from: changedFiles)
            var files: [Reply.DiffFileDTO]?
            var truncated: Bool?
            var truncationNote: String?

            if detail == "files" || includesHunks {
                files = diffFileDTOsWithoutHunks(from: changedFiles)
            }
            if includesHunks, let perFilePatches {
                let parsedFiles = parsedFileHunks(
                    changedFiles: changedFiles,
                    perFilePatches: perFilePatches
                )
                let truncation = GitDiffPatchParsing.truncatePatches(
                    files: parsedFiles,
                    maxLines: maxLinesForPatches
                )
                truncated = truncation.truncated
                truncationNote = truncation.note
                files = truncation.files.map { file in
                    Reply.DiffFileDTO(
                        path: file.path,
                        status: file.status,
                        insertions: file.insertions,
                        deletions: file.deletions,
                        hunks: hunkDTOs(from: file.hunks, nilWhenEmpty: false)
                    )
                }
            }

            return Reply.DiffDTO(
                compare: compare,
                detail: detail,
                files: files,
                totals: totals,
                byStatus: statusBreakdown(from: changedFiles),
                oneliner: oneliner(
                    files: totals.files,
                    insertions: totals.insertions,
                    deletions: totals.deletions
                ),
                truncated: truncated,
                truncationNote: truncationNote
            )
        }
    }

    @MainActor
    static func makeArtifactProjection(
        snapshotDirURL: URL,
        snapshotDir: String,
        manifest: GitDiffSnapshotManifest,
        compareDisplay: String,
        mode: GitDiffPublishMode,
        inlineMap: Bool,
        inlineMode: String,
        inlineMaxLines: Int
    ) async throws -> ArtifactProjection {
        try await MCPProviderProjectionWorker.run(toolName: MCPWindowToolName.git, phase: "artifact_projection") {
            let dtoState = EditFlowPerf.begin(EditFlowPerf.Stage.Git.dtoConstruction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.Git.dtoConstruction, dtoState) }

            let summary = summaryDTO(summary: manifest.summary, files: manifest.files)
            let artifacts = artifactsDTO(snapshotDirURL: snapshotDirURL, manifest: manifest)
            let primary = GitDiffSnapshotStore.primaryArtifacts(
                snapshotDir: snapshotDir,
                mapRelativePath: artifacts.map,
                allPatchRelativePath: artifacts.allPatch
            )
            return ArtifactProjection(
                diff: Reply.DiffDTO(
                    compare: compareDisplay,
                    detail: nil,
                    files: nil,
                    totals: Reply.TotalsDTO(
                        files: summary.files,
                        insertions: summary.insertions,
                        deletions: summary.deletions
                    ),
                    byStatus: summary.byStatus,
                    oneliner: oneliner(
                        files: summary.files,
                        insertions: summary.insertions,
                        deletions: summary.deletions
                    ),
                    truncated: nil,
                    truncationNote: nil
                ),
                artifacts: artifacts,
                summary: summary,
                oneliner: "\(summary.files) files (+\(summary.insertions) -\(summary.deletions)) | \(snapshotDir)",
                inputs: Reply.DiffInputsDTO(
                    compare: manifest.compare,
                    compareInput: manifest.compareInput,
                    scope: manifest.scope.rawValue,
                    requestedPathsCount: manifest.requestedPaths?.count,
                    contextLines: manifest.contextLines,
                    detectRenames: manifest.detectRenames
                ),
                modeDetails: GitDiffMapBuilder.modeDetails(for: mode),
                inline: inlineDTO(
                    snapshotDirURL: snapshotDirURL,
                    inlineMap: inlineMap,
                    inlineMode: inlineMode,
                    inlineMaxLines: inlineMaxLines
                ),
                emptyReason: GitDiffMapBuilder.emptyReason(
                    summary: manifest.summary,
                    scope: manifest.scope,
                    requestedPaths: manifest.requestedPaths,
                    compareRaw: manifest.compare
                ),
                primaryArtifactCandidates: primary.selectionCandidates
            )
        }
    }

    @MainActor
    static func makePrimaryArtifactsDTO(
        snapshotDir: String,
        artifacts: Reply.ArtifactsDTO,
        manifest: GitDiffSnapshotManifest,
        autoSelectedPaths: [String]
    ) async throws -> Reply.PrimaryArtifactsDTO {
        try await MCPProviderProjectionWorker.run(toolName: MCPWindowToolName.git, phase: "primary_artifacts_dto") {
            primaryArtifactsDTO(
                snapshotDir: snapshotDir,
                artifacts: artifacts,
                manifest: manifest,
                autoSelectedPaths: autoSelectedPaths
            )
        }
    }

    @MainActor
    static func decorateArtifactRepoResults(
        _ repoResults: [Reply.RepoResultDTO],
        manifestsBySnapshotDir: [String: GitDiffSnapshotManifest],
        autoSelectedPaths: [String]
    ) async throws -> [Reply.RepoResultDTO] {
        try await MCPProviderProjectionWorker.run(toolName: MCPWindowToolName.git, phase: "artifact_repo_dto") {
            let state = EditFlowPerf.begin(EditFlowPerf.Stage.Git.dtoConstruction)
            defer { EditFlowPerf.end(EditFlowPerf.Stage.Git.dtoConstruction, state) }
            return repoResults.map { repoResult in
                guard let snapshotDir = repoResult.snapshotDir,
                      let artifacts = repoResult.artifacts,
                      let manifest = manifestsBySnapshotDir[snapshotDir]
                else {
                    return repoResult
                }
                return Reply.RepoResultDTO(
                    repoRoot: repoResult.repoRoot,
                    repoKey: repoResult.repoKey,
                    repoName: repoResult.repoName,
                    status: repoResult.status,
                    diff: repoResult.diff,
                    log: repoResult.log,
                    show: repoResult.show,
                    blame: repoResult.blame,
                    worktree: repoResult.worktree,
                    snapshotId: repoResult.snapshotId,
                    snapshotDir: snapshotDir,
                    artifacts: artifacts,
                    primaryArtifacts: primaryArtifactsDTO(
                        snapshotDir: snapshotDir,
                        artifacts: artifacts,
                        manifest: manifest,
                        autoSelectedPaths: autoSelectedPaths
                    ),
                    summary: repoResult.summary,
                    oneliner: repoResult.oneliner,
                    inputs: repoResult.inputs,
                    modeDetails: repoResult.modeDetails,
                    inline: repoResult.inline,
                    warning: repoResult.warning,
                    emptyReason: repoResult.emptyReason,
                    error: repoResult.error
                )
            }
        }
    }

    @MainActor
    static func makeAggregateDTO(from repoDiffs: [Reply.DiffDTO], repoCount: Int) async throws -> Reply.AggregateDTO {
        try await MCPProviderProjectionWorker.run(toolName: MCPWindowToolName.git, phase: "aggregate_dto") {
            let totals = repoDiffs.reduce(into: (files: 0, insertions: 0, deletions: 0)) { result, diff in
                result.files += diff.totals.files
                result.insertions += diff.totals.insertions
                result.deletions += diff.totals.deletions
            }
            var byStatus: [String: Int] = [:]
            for diff in repoDiffs {
                for (status, count) in diff.byStatus ?? [:] {
                    byStatus[status, default: 0] += count
                }
            }
            let totalsDTO = Reply.TotalsDTO(
                files: totals.files,
                insertions: totals.insertions,
                deletions: totals.deletions
            )
            return Reply.AggregateDTO(
                totals: totalsDTO,
                byStatus: byStatus.isEmpty ? nil : byStatus,
                oneliner: "\(repoCount) repos: \(totals.files) files (+\(totals.insertions) -\(totals.deletions))",
                repoCount: repoCount
            )
        }
    }

    private nonisolated static func totals(from files: [VCSUncommittedFile]) -> Reply.TotalsDTO {
        Reply.TotalsDTO(
            files: files.count,
            insertions: files.reduce(0) { $0 + ($1.additions ?? 0) },
            deletions: files.reduce(0) { $0 + ($1.deletions ?? 0) }
        )
    }

    private nonisolated static func statusBreakdown(from files: [VCSUncommittedFile]) -> [String: Int]? {
        var counts: [String: Int] = [:]
        for file in files {
            counts[file.status, default: 0] += 1
        }
        return counts.isEmpty ? nil : counts
    }

    private nonisolated static func statusBreakdown(from files: [GitDiffSnapshotManifest.FileEntry]) -> [String: Int]? {
        var counts: [String: Int] = [:]
        for file in files {
            guard let status = file.status, !status.isEmpty else { continue }
            counts[status, default: 0] += 1
        }
        return counts.isEmpty ? nil : counts
    }

    private nonisolated static func summaryDTO(
        summary: GitDiffSnapshotManifest.Summary,
        files: [GitDiffSnapshotManifest.FileEntry]
    ) -> Reply.SummaryDTO {
        Reply.SummaryDTO(
            files: summary.files,
            insertions: summary.insertions,
            deletions: summary.deletions,
            byStatus: statusBreakdown(from: files)
        )
    }

    private nonisolated static func oneliner(files: Int, insertions: Int, deletions: Int) -> String {
        "\(files) files (+\(insertions) -\(deletions))"
    }

    private nonisolated static func hunkDTOs(
        from hunks: [GitDiffPatchParsing.ParsedHunk],
        nilWhenEmpty: Bool
    ) -> [Reply.DiffHunkDTO]? {
        if nilWhenEmpty, hunks.isEmpty { return nil }
        return hunks.map { hunk in
            Reply.DiffHunkDTO(
                header: hunk.header,
                oldStart: hunk.oldStart,
                newStart: hunk.newStart,
                patch: hunk.content
            )
        }
    }

    private nonisolated static func diffFileDTOsWithoutHunks(
        from changedFiles: [VCSUncommittedFile]
    ) -> [Reply.DiffFileDTO] {
        changedFiles.map { file in
            Reply.DiffFileDTO(
                path: file.path,
                status: file.status,
                insertions: file.additions,
                deletions: file.deletions,
                hunks: nil
            )
        }
    }

    private nonisolated static func filesWithParsedHunks(
        changedFiles: [VCSUncommittedFile],
        perFilePatches: [String: String],
        nilWhenEmpty: Bool
    ) -> [Reply.DiffFileDTO] {
        let state = EditFlowPerf.begin(
            EditFlowPerf.Stage.Git.hunkParsing,
            EditFlowPerf.Dimensions(lineCount: changedFiles.count)
        )
        var patchBytes = 0
        var hunkCount = 0
        let files = changedFiles.map { file in
            let patchText = perFilePatches[file.path] ?? ""
            if state != nil {
                patchBytes += patchText.utf8.count
            }
            let hunks = patchText.isEmpty ? [] : GitDiffPatchParsing.parseHunks(from: patchText)
            hunkCount += hunks.count
            return Reply.DiffFileDTO(
                path: file.path,
                status: file.status,
                insertions: file.additions,
                deletions: file.deletions,
                hunks: hunkDTOs(from: hunks, nilWhenEmpty: nilWhenEmpty)
            )
        }
        EditFlowPerf.end(
            EditFlowPerf.Stage.Git.hunkParsing,
            state,
            EditFlowPerf.Dimensions(
                fileBytes: patchBytes,
                lineCount: changedFiles.count,
                chunkCount: hunkCount
            )
        )
        return files
    }

    private nonisolated static func parsedFileHunks(
        changedFiles: [VCSUncommittedFile],
        perFilePatches: [String: String]
    ) -> [GitDiffPatchParsing.ParsedFileHunks] {
        let state = EditFlowPerf.begin(
            EditFlowPerf.Stage.Git.hunkParsing,
            EditFlowPerf.Dimensions(lineCount: changedFiles.count)
        )
        var parsedFiles: [GitDiffPatchParsing.ParsedFileHunks] = []
        parsedFiles.reserveCapacity(changedFiles.count)
        var patchBytes = 0
        var hunkCount = 0

        for file in changedFiles {
            guard let patchText = perFilePatches[file.path] else { continue }
            if state != nil {
                patchBytes += patchText.utf8.count
            }
            let hunks = patchText.isEmpty ? [] : GitDiffPatchParsing.parseHunks(from: patchText)
            hunkCount += hunks.count
            parsedFiles.append(GitDiffPatchParsing.ParsedFileHunks(
                path: file.path,
                status: file.status,
                insertions: file.additions ?? 0,
                deletions: file.deletions ?? 0,
                hunks: hunks
            ))
        }

        EditFlowPerf.end(
            EditFlowPerf.Stage.Git.hunkParsing,
            state,
            EditFlowPerf.Dimensions(
                fileBytes: patchBytes,
                lineCount: changedFiles.count,
                chunkCount: hunkCount
            )
        )
        return parsedFiles
    }

    private nonisolated static func artifactsDTO(
        snapshotDirURL: URL,
        manifest: GitDiffSnapshotManifest
    ) -> Reply.ArtifactsDTO {
        let fileManager = FileManager.default
        return Reply.ArtifactsDTO(
            manifest: "manifest.json",
            map: "MAP.txt",
            filesTsv: "index/files.tsv",
            changedLines: fileManager.fileExists(
                atPath: snapshotDirURL.appendingPathComponent("index/changed_lines.tsv").path
            ) ? "index/changed_lines.tsv" : nil,
            tree: "index/files.tree.txt",
            selectionPaths: manifest.requestedPaths == nil ? nil : "index/selection.paths.txt",
            allPatch: fileManager.fileExists(
                atPath: snapshotDirURL.appendingPathComponent("diff/all.patch").path
            ) ? "diff/all.patch" : nil,
            deepHunks: fileManager.fileExists(
                atPath: snapshotDirURL.appendingPathComponent("deep/hunks.jsonl").path
            ) ? "deep/hunks.jsonl" : nil,
            deepChangedLines: fileManager.fileExists(
                atPath: snapshotDirURL.appendingPathComponent("deep/changed_lines.tsv").path
            ) ? "deep/changed_lines.tsv" : nil
        )
    }

    private nonisolated static func inlineDTO(
        snapshotDirURL: URL,
        inlineMap: Bool,
        inlineMode: String,
        inlineMaxLines: Int
    ) -> Reply.InlineDTO? {
        guard inlineMap else { return nil }
        let state = EditFlowPerf.begin(EditFlowPerf.Stage.Git.mapLoadingExcerpting)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.Git.mapLoadingExcerpting, state) }
        let mapURL = snapshotDirURL.appendingPathComponent("MAP.txt")
        guard let mapText = try? String(contentsOf: mapURL, encoding: .utf8) else { return nil }
        let sections = inlineMode == "brief" ? ["SNAPSHOT_META", "CHANGED_FILE_TREE"] : nil
        let excerpt = GitDiffMapBuilder.inlineExcerpt(
            from: mapText,
            maxLines: inlineMaxLines,
            sections: sections
        )
        return Reply.InlineDTO(
            mapExcerpt: excerpt.excerpt,
            truncated: excerpt.truncated,
            totalLines: excerpt.totalLines,
            returnedLines: excerpt.returnedLines
        )
    }

    private nonisolated static func primaryArtifactsDTO(
        snapshotDir: String,
        artifacts: Reply.ArtifactsDTO,
        manifest: GitDiffSnapshotManifest,
        autoSelectedPaths: [String]
    ) -> Reply.PrimaryArtifactsDTO {
        let primary = GitDiffSnapshotStore.primaryArtifacts(
            snapshotDir: snapshotDir,
            mapRelativePath: artifacts.map,
            allPatchRelativePath: artifacts.allPatch
        )
        let autoSelected = primary.selectionCandidates.filter(autoSelectedPaths.contains)
        let perFilePatches = GitDiffSnapshotStore.perFilePatchArtifacts(
            snapshotDir: snapshotDir,
            files: manifest.files
        ).map { patch in
            Reply.PrimaryArtifactsDTO.PerFilePatchDTO(
                jumpIndex: patch.jumpIndex,
                gitPath: patch.gitPath,
                selectionPath: patch.selectionPath,
                status: patch.status,
                additions: patch.additions,
                deletions: patch.deletions
            )
        }
        return Reply.PrimaryArtifactsDTO(
            map: primary.map,
            allPatch: primary.allPatch,
            autoSelected: autoSelected.isEmpty ? nil : autoSelected,
            perFilePatches: perFilePatches.isEmpty ? nil : perFilePatches
        )
    }
}
