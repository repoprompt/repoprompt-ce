import Foundation

/// Sendable read-file slicing and reply projection used by the MainActor provider.
enum MCPReadFileToolProjection {
    struct PreparedReply {
        let reply: ToolResultDTOs.ReadFileReply
        let returnedLineCount: Int
    }

    @MainActor
    static func makeBaseReply(
        preparedContent: WorkspaceInteractiveReadPreparedContent,
        startLine1Based: Int?,
        lineCount: Int?,
        displayPath: String
    ) async throws -> PreparedReply {
        try await MCPProviderProjectionWorker.run(
            toolName: MCPWindowToolName.readFile,
            phase: "prepared_slice_dto"
        ) {
            let slice = try WorkspaceInteractiveReadProcessor.slice(
                preparedContent,
                startLine1Based: startLine1Based,
                lineCount: lineCount
            )
            return PreparedReply(
                reply: ToolResultDTOs.ReadFileReply(
                    content: slice.content,
                    totalLines: slice.totalLines,
                    firstLine: slice.firstLine,
                    lastLine: slice.lastLine,
                    message: slice.startExceededFileLength
                        ? "Requested start_line exceeds file length."
                        : nil,
                    displayPath: displayPath
                ),
                returnedLineCount: slice.returnedLineCount
            )
        }
    }

    @MainActor
    static func projectReply(
        _ reply: ToolResultDTOs.ReadFileReply,
        displayPath: String?,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO?
    ) async throws -> ToolResultDTOs.ReadFileReply {
        try await MCPProviderProjectionWorker.run(
            toolName: MCPWindowToolName.readFile,
            phase: "reply_projection"
        ) {
            ToolResultDTOs.ReadFileReply(
                content: reply.content,
                totalLines: reply.totalLines,
                firstLine: reply.firstLine,
                lastLine: reply.lastLine,
                message: reply.message,
                displayPath: displayPath,
                worktreeScope: worktreeScope
            )
        }
    }
}
