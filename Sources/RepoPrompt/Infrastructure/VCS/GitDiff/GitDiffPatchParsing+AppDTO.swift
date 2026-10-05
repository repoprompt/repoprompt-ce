import RepoPromptVCS

extension GitDiffPatchParsing {
    /// Converts ParsedFileHunks to the DTO format.
    static func toDiffFileDTO(
        _ file: ParsedFileHunks,
        includeHunks: Bool
    ) -> ToolResultDTOs.GitToolReplyDTO.DiffFileDTO {
        let hunks: [ToolResultDTOs.GitToolReplyDTO.DiffHunkDTO]? = includeHunks ? file.hunks.map { hunk in
            ToolResultDTOs.GitToolReplyDTO.DiffHunkDTO(
                header: hunk.header,
                oldStart: hunk.oldStart,
                newStart: hunk.newStart,
                patch: hunk.content
            )
        } : nil

        return ToolResultDTOs.GitToolReplyDTO.DiffFileDTO(
            path: file.path,
            status: file.status,
            insertions: file.insertions,
            deletions: file.deletions,
            hunks: hunks
        )
    }
}
