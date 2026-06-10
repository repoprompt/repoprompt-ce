import Foundation

/// Namespace for MCP Tool result DTOs.
/// Using a namespace avoids name collisions with existing private structs
/// in MCPServerViewModel during the migration phase.
enum ToolResultDTOs {
    // MARK: - Worktree Scope

    struct WorktreeScopeDTO: Codable, Equatable {
        struct RootMappingDTO: Codable, Equatable {
            let logicalRootName: String
            let logicalRootPath: String
            let effectiveRootName: String
            let effectiveRootPath: String
            let worktreeID: String
            let worktreeName: String?
            let branch: String?
            let label: String?

            private enum CodingKeys: String, CodingKey {
                case logicalRootName = "logical_root_name"
                case logicalRootPath = "logical_root_path"
                case effectiveRootName = "effective_root_name"
                case effectiveRootPath = "effective_root_path"
                case worktreeID = "worktree_id"
                case worktreeName = "worktree_name"
                case branch
                case label
            }
        }

        let kind: String
        let displayIdentity: String
        let effectiveIdentity: String
        let rootMappings: [RootMappingDTO]

        static func sessionBound(from projection: WorkspaceRootBindingProjection?) -> WorktreeScopeDTO? {
            guard let projection, !projection.isEmpty else { return nil }
            let mappings = projection.boundRootsForMetadata.compactMap { boundRoot -> RootMappingDTO? in
                let logicalPath = boundRoot.logicalRoot.standardizedFullPath
                let effectivePath = boundRoot.physicalRoot.standardizedFullPath
                guard logicalPath != effectivePath else { return nil }
                return RootMappingDTO(
                    logicalRootName: boundRoot.logicalRoot.name,
                    logicalRootPath: logicalPath,
                    effectiveRootName: effectiveRootName(for: boundRoot),
                    effectiveRootPath: effectivePath,
                    worktreeID: boundRoot.binding.worktreeID,
                    worktreeName: boundRoot.binding.worktreeName,
                    branch: boundRoot.binding.branch,
                    label: boundRoot.binding.visualLabel
                )
            }
            guard !mappings.isEmpty else { return nil }
            return WorktreeScopeDTO(
                kind: "session_bound_worktree",
                displayIdentity: "logical_canonical_root",
                effectiveIdentity: "bound_worktree_root",
                rootMappings: mappings
            )
        }

        private static func effectiveRootName(for boundRoot: WorkspaceRootBindingProjection.BoundRoot) -> String {
            if let worktreeName = nonEmpty(boundRoot.binding.worktreeName) {
                return worktreeName
            }
            let basename = URL(fileURLWithPath: boundRoot.binding.worktreeRootPath).lastPathComponent
            if !basename.isEmpty {
                return basename
            }
            return boundRoot.physicalRoot.name
        }

        private static func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case displayIdentity = "display_identity"
            case effectiveIdentity = "effective_identity"
            case rootMappings = "root_mappings"
        }
    }

    // MARK: - Search

    struct PerFileCount: Codable, Equatable {
        let path: String
        let count: Int
    }

    struct SearchResultDTO: Codable, Equatable {
        struct ContentMatchGroup: Codable, Equatable {
            struct ContextLine: Codable, Equatable, Hashable {
                let lineNumber: Int
                let lineText: String

                private enum CodingKeys: String, CodingKey {
                    case lineNumber = "line_number"
                    case lineText = "line_text"
                }
            }

            struct Line: Codable, Equatable {
                let lineNumber: Int
                let lineText: String
                let contextBefore: [ContextLine]?
                let contextAfter: [ContextLine]?

                private enum CodingKeys: String, CodingKey {
                    case lineNumber = "line_number"
                    case lineText = "line_text"
                    case contextBefore = "context_before"
                    case contextAfter = "context_after"
                }
            }

            let path: String
            let lines: [Line]

            private enum CodingKeys: String, CodingKey {
                case path
                case lines
            }
        }

        let totalMatches: Int
        let totalFiles: Int
        let matchedFiles: Int?
        let searchedFiles: Int?
        let contentMatches: Int
        let pathMatches: Int
        let limitHit: Bool
        let perFileCounts: [PerFileCount]
        let pathMatchLines: [String]
        let contentMatchGroups: [ContentMatchGroup]

        // NEW (optional, default nil) — indicates size-based trimming
        let sizeLimitHit: Bool?
        let omittedTotal: Int?
        let omittedContentMatches: Int?
        let omittedPathMatches: Int?
        let errorMessage: String?
        let errorCode: String?
        let retryable: Bool?
        let retryAfterMilliseconds: Int?
        let suggestion: String?
        let warning: String?
        let perFileTotals: [PerFileCount]?
        let worktreeScope: WorktreeScopeDTO?

        /// Custom initializer to keep existing call sites source-compatible while allowing optional size-cap fields.
        init(
            totalMatches: Int,
            totalFiles: Int,
            matchedFiles: Int? = nil,
            searchedFiles: Int? = nil,
            contentMatches: Int,
            pathMatches: Int,
            limitHit: Bool,
            perFileCounts: [PerFileCount],
            pathMatchLines: [String],
            contentMatchGroups: [ContentMatchGroup],
            sizeLimitHit: Bool? = nil,
            omittedTotal: Int? = nil,
            omittedContentMatches: Int? = nil,
            omittedPathMatches: Int? = nil,
            errorMessage: String? = nil,
            errorCode: String? = nil,
            retryable: Bool? = nil,
            retryAfterMilliseconds: Int? = nil,
            suggestion: String? = nil,
            warning: String? = nil,
            perFileTotals: [PerFileCount]? = nil,
            worktreeScope: WorktreeScopeDTO? = nil
        ) {
            self.totalMatches = totalMatches
            self.totalFiles = totalFiles
            self.matchedFiles = matchedFiles
            self.searchedFiles = searchedFiles
            self.contentMatches = contentMatches
            self.pathMatches = pathMatches
            self.limitHit = limitHit
            self.perFileCounts = perFileCounts
            self.pathMatchLines = pathMatchLines
            self.contentMatchGroups = contentMatchGroups
            self.sizeLimitHit = sizeLimitHit
            self.omittedTotal = omittedTotal
            self.omittedContentMatches = omittedContentMatches
            self.omittedPathMatches = omittedPathMatches
            self.errorMessage = errorMessage
            self.errorCode = errorCode
            self.retryable = retryable
            self.retryAfterMilliseconds = retryAfterMilliseconds
            self.suggestion = suggestion
            self.warning = warning
            self.perFileTotals = perFileTotals
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case totalMatches = "total_matches"
            case totalFiles = "total_files"
            case matchedFiles = "matched_files"
            case searchedFiles = "searched_files"
            case contentMatches = "content_matches"
            case pathMatches = "path_matches"
            case limitHit = "limit_hit"
            case perFileCounts = "per_file_counts"
            case pathMatchLines = "path_match_lines"
            case contentMatchGroups = "content_match_groups"

            // NEW keys
            case sizeLimitHit = "size_limit_hit"
            case omittedTotal = "omitted_total"
            case omittedContentMatches = "omitted_content_matches"
            case omittedPathMatches = "omitted_path_matches"
            case errorMessage = "error"
            case errorCode = "error_code"
            case retryable
            case retryAfterMilliseconds = "retry_after_ms"
            case suggestion
            case warning
            case perFileTotals = "per_file_totals"
            case worktreeScope = "worktree_scope"
        }
    }

    // MARK: - File Tree

    struct FileTreeDTO: Codable, Equatable {
        let rootsCount: Int
        let usesLegend: Bool
        let tree: String
        let note: String?
        let wasTruncated: Bool?
        let worktreeScope: WorktreeScopeDTO?

        init(
            rootsCount: Int,
            usesLegend: Bool,
            tree: String,
            note: String? = nil,
            wasTruncated: Bool? = nil,
            worktreeScope: WorktreeScopeDTO? = nil
        ) {
            self.rootsCount = rootsCount
            self.usesLegend = usesLegend
            self.tree = tree
            self.note = note
            self.wasTruncated = wasTruncated
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case rootsCount = "roots_count"
            case usesLegend = "uses_legend"
            case tree
            case note
            case wasTruncated = "was_truncated"
            case worktreeScope = "worktree_scope"
        }
    }

    // MARK: - Code Structure

    struct SelectedCodeStructureDTO: Codable, Equatable {
        let fileCount: Int
        let content: String
        /// Paths (display-form) that are selected but have **no codemap** available
        let unmappedPaths: [String]?
        /// Paths whose targeted codemap repair did not finish before the bounded wait expired
        let pendingPaths: [String]?
        /// Number of additional files with codemaps omitted due to `max_results` cap
        let omittedCount: Int?
        /// Total number of codemaps omitted due to all limits
        let omittedTotal: Int?
        /// Number of codemaps omitted due to the response token budget
        let tokenBudgetOmittedCount: Int?
        /// Indicates the response token budget prevented more codemaps from being emitted
        let tokenBudgetHit: Bool?
        let worktreeScope: WorktreeScopeDTO?

        init(
            fileCount: Int,
            content: String,
            unmappedPaths: [String]? = nil,
            pendingPaths: [String]? = nil,
            omittedCount: Int? = nil,
            omittedTotal: Int? = nil,
            tokenBudgetOmittedCount: Int? = nil,
            tokenBudgetHit: Bool? = nil,
            worktreeScope: WorktreeScopeDTO? = nil
        ) {
            self.fileCount = fileCount
            self.content = content
            self.unmappedPaths = unmappedPaths
            self.pendingPaths = pendingPaths
            self.omittedCount = omittedCount
            self.omittedTotal = omittedTotal
            self.tokenBudgetOmittedCount = tokenBudgetOmittedCount
            self.tokenBudgetHit = tokenBudgetHit
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case fileCount = "file_count"
            case content
            case unmappedPaths = "unmapped_paths"
            case pendingPaths = "pending_paths"
            case omittedCount = "codemaps_omitted"
            case omittedTotal = "omitted_total"
            case tokenBudgetOmittedCount = "token_budget_omitted"
            case tokenBudgetHit = "token_budget_hit"
            case worktreeScope = "worktree_scope"
        }
    }

    // MARK: - Selected Files Content (bulk read)

    // (Removed) SelectedFilesContentDTO — superseded by workspace_context `file_blocks`

    // MARK: - Prompt State (legacy)

    struct PromptStateReply: Codable, Equatable {
        let prompt: String
        let selectedPaths: [String]
        /// Optional line-range slices for selected files.
        /// Only includes paths with actual slices; full-file selections are represented only in `selectedPaths`.
        let fileSlices: [FileSliceDTO]?

        private enum CodingKeys: String, CodingKey {
            case prompt
            case selectedPaths = "selected_paths"
            case fileSlices = "file_slices"
        }
    }

    // MARK: - Selection (list and mutations)

    struct LineRangeDTO: Codable, Equatable {
        let startLine: Int
        let endLine: Int
        /// Optional description explaining what this slice contains and why it's relevant
        let description: String?

        init(startLine: Int, endLine: Int, description: String? = nil) {
            self.startLine = startLine
            self.endLine = endLine
            self.description = description
        }

        init(range: LineRange) {
            self.init(startLine: range.start, endLine: range.end, description: range.description)
        }

        private enum CodingKeys: String, CodingKey {
            case startLine = "start_line"
            case endLine = "end_line"
            case description
        }
    }

    struct FileSliceDTO: Codable, Equatable {
        let path: String
        let ranges: [LineRangeDTO]
        /// Absolute workspace/root path for markdown grouping. `path` remains the requested display path.
        let rootPath: String?
        /// File path relative to `rootPath`, used for markdown tree rendering.
        let pathWithinRoot: String?

        init(
            path: String,
            ranges: [LineRangeDTO],
            rootPath: String? = nil,
            pathWithinRoot: String? = nil
        ) {
            self.path = path
            self.ranges = ranges
            self.rootPath = rootPath
            self.pathWithinRoot = pathWithinRoot
        }

        private enum CodingKeys: String, CodingKey {
            case path
            case ranges
            case rootPath = "root_path"
            case pathWithinRoot = "path_within_root"
        }
    }

    struct SelectedFileInfo: Codable, Equatable {
        /// How a file would render under the user's copy preset (when different from auto view)
        struct CopyPresetProjection: Codable, Equatable {
            let tokens: Int
            let renderMode: String // "full" | "slice" | "codemap" | "hidden"
            let ranges: [LineRangeDTO]? // for slice
            let codemapOrigin: String? // if codemap: "selected_mode", etc.

            private enum CodingKeys: String, CodingKey {
                case tokens
                case renderMode = "render_mode"
                case ranges
                case codemapOrigin = "codemap_origin"
            }
        }

        let path: String
        let tokens: Int
        let renderMode: String
        let ranges: [LineRangeDTO]?
        let isAuto: Bool
        /// Why this file is rendered as a codemap: "auto", "manual", or "selected_mode". Nil for non-codemap files.
        let codemapOrigin: String?
        /// How this file would render under the user's copy preset (only set when it differs from auto view)
        let copyPreset: CopyPresetProjection?
        /// Absolute workspace/root path for markdown grouping. `path` remains the requested display path.
        let rootPath: String?
        /// File path relative to `rootPath`, used for markdown tree rendering.
        let pathWithinRoot: String?

        init(
            path: String,
            tokens: Int,
            renderMode: String,
            ranges: [LineRangeDTO]?,
            isAuto: Bool,
            codemapOrigin: String?,
            copyPreset: CopyPresetProjection?,
            rootPath: String? = nil,
            pathWithinRoot: String? = nil
        ) {
            self.path = path
            self.tokens = tokens
            self.renderMode = renderMode
            self.ranges = ranges
            self.isAuto = isAuto
            self.codemapOrigin = codemapOrigin
            self.copyPreset = copyPreset
            self.rootPath = rootPath
            self.pathWithinRoot = pathWithinRoot
        }

        private enum CodingKeys: String, CodingKey {
            case path
            case tokens
            case renderMode = "render_mode"
            case ranges
            case isAuto = "is_auto"
            case codemapOrigin = "codemap_origin"
            case copyPreset = "copy_preset"
            case rootPath = "root_path"
            case pathWithinRoot = "path_within_root"
        }
    }

    struct SelectionSummary: Codable, Equatable {
        let fullCount: Int
        let sliceCount: Int
        let codemapCount: Int
        let fullTokens: Int
        let sliceTokens: Int
        let codemapTokens: Int

        private enum CodingKeys: String, CodingKey {
            case fullCount = "full_count"
            case sliceCount = "slice_count"
            case codemapCount = "codemap_count"
            case fullTokens = "full_tokens"
            case sliceTokens = "slice_tokens"
            case codemapTokens = "codemap_tokens"
        }
    }

    struct SelectedFilesReply: Codable, Equatable {
        let files: [SelectedFileInfo]
        let totalTokens: Int
        let fileSlices: [FileSliceDTO]?
        let summary: SelectionSummary?
        /// The active codemap usage mode: "auto", "complete", "selected", or "none"
        var codeMapUsage: String? = nil

        // MARK: - User Preset State Indicators (for virtual contexts)

        /// User's copy preset codemap mode (so builder knows user's actual view)
        var userCopyCodeMapUsage: String? = nil
        /// User's chat preset codemap mode
        var userChatCodeMapUsage: String? = nil
        /// Token count under user's copy preset settings
        var userCopyTokens: Int? = nil
        /// Token count under user's chat preset settings
        var userChatTokens: Int? = nil
        /// What this reply uses (e.g. "auto" for virtual contexts, nil if live)
        var normalizedCodeMapUsage: String? = nil
        /// Summary of how selection would render under the effective copy preset (when it differs from auto)
        var copyPresetProjection: CopyPresetProjectionSummaryDTO? = nil
        /// Content tokens (full + slice) under user's copy preset settings
        var userCopyContentTokens: Int? = nil
        /// Codemap tokens under user's copy preset settings (0 when codemaps disabled)
        var userCopyCodemapTokens: Int? = nil

        private enum CodingKeys: String, CodingKey {
            case files
            case totalTokens = "total_tokens"
            case fileSlices = "file_slices"
            case summary
            case codeMapUsage = "code_map_usage"
            case userCopyCodeMapUsage = "user_copy_codemap_usage"
            case userChatCodeMapUsage = "user_chat_codemap_usage"
            case userCopyTokens = "user_copy_tokens"
            case userChatTokens = "user_chat_tokens"
            case normalizedCodeMapUsage = "normalized_codemap_usage"
            case copyPresetProjection = "copy_preset_projection"
            case userCopyContentTokens = "user_copy_content_tokens"
            case userCopyCodemapTokens = "user_copy_codemap_tokens"
        }
    }

    struct SelectionReply: Codable, Equatable {
        let files: [SelectedFileInfo]?
        let totalTokens: Int?
        let status: String
        let invalidPaths: [String]?
        /// When `manage_selection` action=`list` and `include_content=true`
        let blocks: [String]?
        /// Compact code-map summary for the current selection (no large content)
        let codeStructure: SelectedCodeStructureDTO?
        let fileSlices: [FileSliceDTO]?
        let codemapAutoEnabled: Bool?
        let summary: SelectionSummary?
        /// The active codemap usage mode: "auto", "complete", "selected", or "none"
        let codeMapUsage: String?

        // MARK: - User Preset State Indicators (for virtual contexts)

        /// User's copy preset codemap mode (so builder knows user's actual view)
        let userCopyCodeMapUsage: String?
        /// User's chat preset codemap mode
        let userChatCodeMapUsage: String?
        /// Token count under user's copy preset settings
        let userCopyTokens: Int?
        /// Token count under user's chat preset settings
        let userChatTokens: Int?
        /// What this reply uses (e.g. "auto" for virtual contexts, nil if live)
        let normalizedCodeMapUsage: String?
        /// Workspace token breakdown (total includes prompt, file tree, meta, git, etc.)
        let tokenStats: TokenStats?
        /// Summary of how selection would render under the effective copy preset (when it differs from auto)
        let copyPresetProjection: CopyPresetProjectionSummaryDTO?

        /// Explicit initializer with tokenStats defaulting to nil for source compatibility
        init(
            files: [SelectedFileInfo]?,
            totalTokens: Int?,
            status: String,
            invalidPaths: [String]? = nil,
            blocks: [String]? = nil,
            codeStructure: SelectedCodeStructureDTO? = nil,
            fileSlices: [FileSliceDTO]? = nil,
            codemapAutoEnabled: Bool? = nil,
            summary: SelectionSummary? = nil,
            codeMapUsage: String? = nil,
            userCopyCodeMapUsage: String? = nil,
            userChatCodeMapUsage: String? = nil,
            userCopyTokens: Int? = nil,
            userChatTokens: Int? = nil,
            normalizedCodeMapUsage: String? = nil,
            tokenStats: TokenStats? = nil,
            copyPresetProjection: CopyPresetProjectionSummaryDTO? = nil
        ) {
            self.files = files
            self.totalTokens = totalTokens
            self.status = status
            self.invalidPaths = invalidPaths
            self.blocks = blocks
            self.codeStructure = codeStructure
            self.fileSlices = fileSlices
            self.codemapAutoEnabled = codemapAutoEnabled
            self.summary = summary
            self.codeMapUsage = codeMapUsage
            self.userCopyCodeMapUsage = userCopyCodeMapUsage
            self.userChatCodeMapUsage = userChatCodeMapUsage
            self.userCopyTokens = userCopyTokens
            self.userChatTokens = userChatTokens
            self.normalizedCodeMapUsage = normalizedCodeMapUsage
            self.tokenStats = tokenStats
            self.copyPresetProjection = copyPresetProjection
        }

        private enum CodingKeys: String, CodingKey {
            case files
            case totalTokens = "total_tokens"
            case status
            case invalidPaths = "invalid_paths"
            case blocks
            case codeStructure = "code_structure"
            case fileSlices = "file_slices"
            case codemapAutoEnabled = "codemap_auto_enabled"
            case summary
            case codeMapUsage = "code_map_usage"
            case userCopyCodeMapUsage = "user_copy_codemap_usage"
            case userChatCodeMapUsage = "user_chat_codemap_usage"
            case userCopyTokens = "user_copy_tokens"
            case userChatTokens = "user_chat_tokens"
            case normalizedCodeMapUsage = "normalized_codemap_usage"
            case tokenStats = "token_stats"
            case copyPresetProjection = "copy_preset_projection"
        }
    }

    // MARK: - Read File

    /// Reply structure for read_file tool, carrying slice metadata
    struct ReadFileReply: Codable, Equatable {
        let content: String
        let totalLines: Int
        let firstLine: Int
        let lastLine: Int
        let message: String?
        let displayPath: String?
        let worktreeScope: WorktreeScopeDTO?

        init(
            content: String,
            totalLines: Int,
            firstLine: Int,
            lastLine: Int,
            message: String? = nil,
            displayPath: String? = nil,
            worktreeScope: WorktreeScopeDTO? = nil
        ) {
            self.content = content
            self.totalLines = totalLines
            self.firstLine = firstLine
            self.lastLine = lastLine
            self.message = message
            self.displayPath = displayPath
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case content
            case totalLines = "total_lines"
            case firstLine = "first_line"
            case lastLine = "last_line"
            case message
            case displayPath = "display_path"
            case worktreeScope = "worktree_scope"
        }
    }

    // MARK: - Apply Edits

    /// Compact summary returned by edit tools.
    ///
    /// Fields:
    /// - totalLinesChanged – sum of absolute line deltas across all committed chunks.
    /// - totalChunks       – number of diff chunks applied.
    struct EditSummary: Codable, Equatable {
        let status: String // "success", "partial", "failed"
        let editsRequested: Int
        let editsApplied: Int
        let addedLines: Int?
        let deletedLines: Int?
        let totalLinesChanged: Int?
        let totalChunks: Int?
        let results: [EditOutcome]? // Provided by diff generator utilities
        let unifiedDiff: String?
        let cardUnifiedDiff: String?
        // Extra context – used for friendlier UI and fallback reporting
        let note: String?
        let fileCreated: Bool?
        let fileOverwritten: Bool?
        let reviewStatus: String?
        let rejectionReason: String?
        let requiresUserApproval: Bool?

        private enum CodingKeys: String, CodingKey {
            case status
            case editsRequested = "edits_requested"
            case editsApplied = "edits_applied"
            case addedLines = "added_lines"
            case deletedLines = "deleted_lines"
            case totalLinesChanged = "total_lines_changed"
            case totalChunks = "total_chunks"
            case results
            case unifiedDiff = "unified_diff"
            case cardUnifiedDiff = "card_unified_diff"
            case note
            case fileCreated = "file_created"
            case fileOverwritten = "file_overwritten"
            case reviewStatus = "review_status"
            case rejectionReason = "rejection_reason"
            case requiresUserApproval = "requires_user_approval"
        }
    }

    struct ApplyPatchSummary: Codable, Equatable {
        struct Change: Codable, Equatable {
            let path: String
            let kind: String
            let movePath: String?
            let diff: String

            private enum CodingKeys: String, CodingKey {
                case path
                case kind
                case movePath = "move_path"
                case diff
            }
        }

        let status: String
        let changes: [Change]
        let output: String?
        let changeCount: Int
        let summaryOnly: Bool?

        private enum CodingKeys: String, CodingKey {
            case status
            case changes
            case output
            case changeCount = "change_count"
            case summaryOnly = "summary_only"
        }
    }

    // MARK: - Cursor Native Edit

    struct CursorNativeEditSummary: Decodable, Equatable {
        struct Content: Decodable, Equatable {
            let type: String?
            let path: String?
            let oldText: String?
            let newText: String?
            let unifiedDiff: String?
            let oldTextTruncated: Bool?
            let newTextTruncated: Bool?
            let diffTruncated: Bool?

            private enum CodingKeys: String, CodingKey {
                case type
                case path
                case oldText
                case newText
                case oldTextSnake = "old_text"
                case newTextSnake = "new_text"
                case unifiedDiff = "unified_diff"
                case cardUnifiedDiff = "card_unified_diff"
                case oldTextTruncated = "oldText_truncated"
                case newTextTruncated = "newText_truncated"
                case oldTextTruncatedSnake = "old_text_truncated"
                case newTextTruncatedSnake = "new_text_truncated"
                case oldTextTruncatedCamel = "oldTextTruncated"
                case newTextTruncatedCamel = "newTextTruncated"
                case diffTruncated = "diff_truncated"
                case diffTruncatedCamel = "diffTruncated"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try container.decodeIfPresent(String.self, forKey: .type)
                path = try container.decodeIfPresent(String.self, forKey: .path)
                oldText = try container.decodeIfPresent(String.self, forKey: .oldText)
                    ?? container.decodeIfPresent(String.self, forKey: .oldTextSnake)
                newText = try container.decodeIfPresent(String.self, forKey: .newText)
                    ?? container.decodeIfPresent(String.self, forKey: .newTextSnake)
                unifiedDiff = try container.decodeIfPresent(String.self, forKey: .unifiedDiff)
                    ?? container.decodeIfPresent(String.self, forKey: .cardUnifiedDiff)
                oldTextTruncated = try container.decodeIfPresent(Bool.self, forKey: .oldTextTruncated)
                    ?? container.decodeIfPresent(Bool.self, forKey: .oldTextTruncatedSnake)
                    ?? container.decodeIfPresent(Bool.self, forKey: .oldTextTruncatedCamel)
                newTextTruncated = try container.decodeIfPresent(Bool.self, forKey: .newTextTruncated)
                    ?? container.decodeIfPresent(Bool.self, forKey: .newTextTruncatedSnake)
                    ?? container.decodeIfPresent(Bool.self, forKey: .newTextTruncatedCamel)
                diffTruncated = try container.decodeIfPresent(Bool.self, forKey: .diffTruncated)
                    ?? container.decodeIfPresent(Bool.self, forKey: .diffTruncatedCamel)
            }
        }

        let status: String?
        let acpStatus: String?
        let kind: String?
        let title: String?
        let content: [Content]?
        let changeCount: Int?
        let summaryOnly: Bool?

        private enum CodingKeys: String, CodingKey {
            case status
            case acpStatus = "acp_status"
            case kind
            case title
            case content
            case changeCount = "change_count"
            case summaryOnly = "summary_only"
        }
    }

    // MARK: - Chat Send

    struct ChatSendDTO: Codable, Equatable {
        struct Diff: Codable, Equatable {
            let path: String
            let patch: String
        }

        let chatID: String?
        let mode: String?
        let response: String?
        let diffs: [Diff]?
        let errors: [String]?

        private enum CodingKeys: String, CodingKey {
            case chatID = "chat_id"
            case mode
            case response
            case diffs
            case patches
            case errors
        }

        init(chatID: String?, mode: String?, response: String?, diffs: [Diff]?, errors: [String]?) {
            self.chatID = chatID
            self.mode = mode
            self.response = response
            self.diffs = diffs
            self.errors = errors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            chatID = try container.decodeIfPresent(String.self, forKey: .chatID)
            mode = try container.decodeIfPresent(String.self, forKey: .mode)
            response = try container.decodeIfPresent(String.self, forKey: .response)
            if let decodedDiffs = try container.decodeIfPresent([Diff].self, forKey: .diffs) {
                diffs = decodedDiffs
            } else {
                diffs = try container.decodeIfPresent([Diff].self, forKey: .patches)
            }
            errors = try container.decodeIfPresent([String].self, forKey: .errors)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(chatID, forKey: .chatID)
            try container.encodeIfPresent(mode, forKey: .mode)
            try container.encodeIfPresent(response, forKey: .response)
            try container.encodeIfPresent(diffs, forKey: .diffs)
            try container.encodeIfPresent(errors, forKey: .errors)
        }
    }

    // MARK: - Context Builder

    struct ContextBuilderDTO: Codable, Equatable {
        let tabID: String?
        let status: String?
        let prompt: String?
        let fileCount: Int?
        let totalTokens: Int?
        let selection: String?
        let responseType: String?
        let plan: ChatSendDTO?
        let review: ChatSendDTO?
        let followUpHint: String?
        let message: String?
        let summary: String?

        private enum CodingKeys: String, CodingKey {
            case tabID = "context_id"
            case status
            case prompt
            case fileCount = "file_count"
            case totalTokens = "total_tokens"
            case selection
            case responseType = "response_type"
            case plan
            case review
            case followUpHint = "follow_up_hint"
            case message
            case summary
        }

        private enum LegacyCodingKeys: String, CodingKey {
            case tabID = "tab_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)

            tabID = try container.decodeIfPresent(String.self, forKey: .tabID)
                ?? legacyContainer.decodeIfPresent(String.self, forKey: .tabID)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
            fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount)
            totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            selection = try container.decodeIfPresent(String.self, forKey: .selection)
            responseType = try container.decodeIfPresent(String.self, forKey: .responseType)
            plan = try container.decodeIfPresent(ChatSendDTO.self, forKey: .plan)
            review = try container.decodeIfPresent(ChatSendDTO.self, forKey: .review)
            followUpHint = try container.decodeIfPresent(String.self, forKey: .followUpHint)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
        }
    }

    // MARK: - Models

    struct SupportedModesInfo: Codable, Equatable {
        let chat: Bool
        let plan: Bool
        let review: Bool
    }

    struct ModelInfo: Codable, Equatable {
        let id: String
        let name: String
        let description: String?
        let supportedModes: SupportedModesInfo?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case supportedModes = "supported_modes"
        }
    }

    struct ListModelsReply: Codable, Equatable {
        let models: [ModelInfo]
        let total: Int
    }

    // MARK: - File Actions

    struct FileActionReply: Codable, Equatable {
        let status: String // "ok" or error/other statuses
        let action: String // "create", "delete", "move"
        let path: String
        let newPath: String? // present for move/rename
        let warning: String?

        init(
            status: String,
            action: String,
            path: String,
            newPath: String?,
            warning: String? = nil
        ) {
            self.status = status
            self.action = action
            self.path = path
            self.newPath = newPath
            self.warning = warning
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case action
            case path
            case newPath = "new_path"
            case warning
        }
    }

    // MARK: - Copy Preset DTOs

    /// Compact identifier for a copy preset
    struct CopyPresetDescriptorDTO: Codable, Equatable {
        let id: String // UUID string
        let name: String
        let kind: String? // CopyPresetKind.rawValue
        let isBuiltIn: Bool

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case kind
            case isBuiltIn = "is_built_in"
        }
    }

    /// Full preset listing with configuration details
    struct CopyPresetListItemDTO: Codable, Equatable {
        let preset: CopyPresetDescriptorDTO
        let description: String?
        let icon: String?

        // Raw preset fields (may be nil meaning "uses workspace/UI defaults")
        let includeFiles: Bool?
        let includeUserPrompt: Bool?
        let includeMetaPrompts: Bool?
        let includeFileTree: Bool?
        let fileTreeMode: String? // "auto"|"full"|"selected"|"none"|nil
        let codeMapUsage: String? // "auto"|"complete"|"selected"|"none"|nil
        let gitInclusion: String? // "none"|"selected"|"complete"|nil

        private enum CodingKeys: String, CodingKey {
            case preset
            case description
            case icon
            case includeFiles = "include_files"
            case includeUserPrompt = "include_user_prompt"
            case includeMetaPrompts = "include_meta_prompts"
            case includeFileTree = "include_file_tree"
            case fileTreeMode = "file_tree_mode"
            case codeMapUsage = "codemap_usage"
            case gitInclusion = "git_inclusion"
        }
    }

    /// Active vs effective preset context (for override scenarios)
    struct CopyPresetContextDTO: Codable, Equatable {
        let active: CopyPresetDescriptorDTO
        let effective: CopyPresetDescriptorDTO // equals active if no override
        let isOverridden: Bool

        private enum CodingKeys: String, CodingKey {
            case active
            case effective
            case isOverridden = "is_overridden"
        }
    }

    /// Summary of how selection would render under a copy preset
    struct CopyPresetProjectionSummaryDTO: Codable, Equatable {
        let codeMapUsage: String
        let includesFiles: Bool
        let totalTokens: Int

        private enum CodingKeys: String, CodingKey {
            case codeMapUsage = "codemap_usage"
            case includesFiles = "includes_files"
            case totalTokens = "total_tokens"
        }
    }

    // MARK: - Unified prompt + selection + context (codemaps-first)

    struct TokenStats: Codable, Equatable {
        let total: Int
        let files: Int
        let prompt: Int?
        let fileTree: Int?
        let meta: Int?
        let git: Int?
        let other: Int?
        /// Token count from full files and slices (excludes codemaps)
        let filesContent: Int?
        /// Token count from codemaps only
        let codemaps: Int?

        init(
            total: Int,
            files: Int,
            prompt: Int? = nil,
            fileTree: Int? = nil,
            meta: Int? = nil,
            git: Int? = nil,
            other: Int? = nil,
            filesContent: Int? = nil,
            codemaps: Int? = nil
        ) {
            self.total = total
            self.files = files
            self.prompt = prompt
            self.fileTree = fileTree
            self.meta = meta
            self.git = git
            self.other = other
            self.filesContent = filesContent
            self.codemaps = codemaps
        }

        private enum CodingKeys: String, CodingKey {
            case total
            case files
            case prompt
            case fileTree = "file_tree"
            case meta
            case git
            case other
            case filesContent = "files_content"
            case codemaps
        }
    }

    // MARK: - Prompt (read/write)

    struct PromptReply: Codable, Equatable {
        let prompt: String
        let lines: Int

        // Preset information
        let copyPresetName: String?
        let chatPresetName: String?
        let chatMode: String? // "chat", "plan", "review"

        // Configuration breakdown (what's included in the prompt)
        let includesFiles: Bool?
        let includesFileTree: Bool?
        let includesCodemaps: Bool?
        let includesGitDiff: Bool?
        let includesUserPrompt: Bool?
        let includesMetaPrompts: Bool?
        let includesStoredPrompts: Bool?

        // Detailed settings
        let fileTreeMode: String? // "auto", "full", "selected", "none"
        let codeMapUsage: String? // "none", "auto", "complete", "selected"
        let gitInclusion: String? // "none", "selected", "complete"

        // Token counts
        let effectiveTokens: Int? // Tokens for the actual prompt being sent
        let fullFilesTokens: Int? // Tokens if full files were included

        // Codemap details (when codemaps are included)
        let codeMapFileCount: Int? // Number of files with codemaps
        let codeMapTokens: Int? // Tokens consumed by codemaps
        let codeMapFiles: [String]? // List of file paths with codemaps

        private enum CodingKeys: String, CodingKey {
            case prompt
            case lines
            case copyPresetName = "copy_preset_name"
            case chatPresetName = "chat_preset_name"
            case chatMode = "chat_mode"
            case includesFiles = "includes_files"
            case includesFileTree = "includes_file_tree"
            case includesCodemaps = "includes_codemaps"
            case includesGitDiff = "includes_git_diff"
            case includesUserPrompt = "includes_user_prompt"
            case includesMetaPrompts = "includes_meta_prompts"
            case includesStoredPrompts = "includes_stored_prompts"
            case fileTreeMode = "file_tree_mode"
            case codeMapUsage = "codemap_usage"
            case gitInclusion = "git_inclusion"
            case effectiveTokens = "effective_tokens"
            case fullFilesTokens = "full_files_tokens"
            case codeMapFileCount = "codemap_file_count"
            case codeMapTokens = "codemap_tokens"
            case codeMapFiles = "codemap_files"
        }
    }

    // MARK: - Prompt Export

    struct PromptExportReply: Codable, Equatable {
        let path: String
        let tokens: Int
        let bytes: Int
        let files: [SelectedFileInfo]
        /// The copy preset used for this export (if overridden or for informational purposes)
        let copyPreset: CopyPresetDescriptorDTO?

        private enum CodingKeys: String, CodingKey {
            case path
            case tokens
            case bytes
            case files
            case copyPreset = "copy_preset"
        }
    }

    /// Reply for list_presets operation
    struct PresetsListReply: Codable, Equatable {
        let presets: [CopyPresetListItemDTO]
    }

    // MARK: - Worktree Management Tool

    struct ManageWorktreeReplyDTO: Codable, Equatable {
        let op: String
        let repository: RepositoryDTO?
        let repositories: [RepositoryDTO]?
        let worktree: WorktreeDTO?
        let worktrees: [WorktreeDTO]?
        let createdWorktree: WorktreeDTO?
        let binding: BindingDTO?
        let bindings: [BindingDTO]?
        let previousBinding: BindingDTO?
        let graph: GraphDTO?
        let merge: MergeDTO?
        let warning: String?
        let error: String?

        init(
            op: String,
            repository: RepositoryDTO? = nil,
            repositories: [RepositoryDTO]? = nil,
            worktree: WorktreeDTO? = nil,
            worktrees: [WorktreeDTO]? = nil,
            createdWorktree: WorktreeDTO? = nil,
            binding: BindingDTO? = nil,
            bindings: [BindingDTO]? = nil,
            previousBinding: BindingDTO? = nil,
            graph: GraphDTO? = nil,
            merge: MergeDTO? = nil,
            warning: String? = nil,
            error: String? = nil
        ) {
            self.op = op
            self.repository = repository
            self.repositories = repositories
            self.worktree = worktree
            self.worktrees = worktrees
            self.createdWorktree = createdWorktree
            self.binding = binding
            self.bindings = bindings
            self.previousBinding = previousBinding
            self.graph = graph
            self.merge = merge
            self.warning = warning
            self.error = error
        }

        private enum CodingKeys: String, CodingKey {
            case op, repository, repositories, worktree, worktrees, binding, bindings, graph, merge, warning, error
            case createdWorktree = "created_worktree"
            case previousBinding = "previous_binding"
        }

        struct RepositoryDTO: Codable, Equatable {
            let repositoryID: String?
            let repoKey: String
            let displayName: String
            let rootPath: String
            let commonGitDir: String?
            let mainWorktreeRoot: String?

            private enum CodingKeys: String, CodingKey {
                case repositoryID = "repository_id"
                case repoKey = "repo_key"
                case displayName = "display_name"
                case rootPath = "root_path"
                case commonGitDir = "common_git_dir"
                case mainWorktreeRoot = "main_worktree_root"
            }
        }

        struct WorktreeDTO: Codable, Equatable {
            let worktreeID: String
            let specifier: String
            let path: String
            let gitDir: String?
            let name: String?
            let branch: String?
            let head: String?
            let isMain: Bool
            let isCurrent: Bool
            let isDetached: Bool
            let isLocked: Bool
            let lockReason: String?
            let isPrunable: Bool
            let prunableReason: String?
            let visual: VisualIdentityDTO?
            let status: StatusDTO?

            private enum CodingKeys: String, CodingKey {
                case worktreeID = "worktree_id"
                case specifier, path
                case gitDir = "git_dir"
                case name, branch, head
                case isMain = "is_main"
                case isCurrent = "is_current"
                case isDetached = "is_detached"
                case isLocked = "is_locked"
                case lockReason = "lock_reason"
                case isPrunable = "is_prunable"
                case prunableReason = "prunable_reason"
                case visual, status
            }
        }

        struct VisualIdentityDTO: Codable, Equatable {
            let label: String?
            let colorHex: String
            let iconName: String
            let markerStyle: String

            private enum CodingKeys: String, CodingKey {
                case label
                case colorHex = "color_hex"
                case iconName = "icon_name"
                case markerStyle = "marker_style"
            }
        }

        struct StatusDTO: Codable, Equatable {
            let staged: Int
            let modified: Int
            let untracked: Int
            let isDirty: Bool

            private enum CodingKeys: String, CodingKey {
                case staged, modified, untracked
                case isDirty = "is_dirty"
            }
        }

        struct BindingDTO: Codable, Equatable {
            let id: String
            let repositoryID: String
            let repoKey: String
            let logicalRootPath: String
            let logicalRootName: String?
            let worktreeID: String
            let worktreeRootPath: String
            let worktreeName: String?
            let branch: String?
            let head: String?
            let visualLabel: String?
            let visualColorHex: String?
            let boundAt: String
            let source: String

            private enum CodingKeys: String, CodingKey {
                case id
                case repositoryID = "repository_id"
                case repoKey = "repo_key"
                case logicalRootPath = "logical_root_path"
                case logicalRootName = "logical_root_name"
                case worktreeID = "worktree_id"
                case worktreeRootPath = "worktree_root_path"
                case worktreeName = "worktree_name"
                case branch, head
                case visualLabel = "visual_label"
                case visualColorHex = "visual_color_hex"
                case boundAt = "bound_at"
                case source
            }
        }

        struct GraphDTO: Codable, Equatable {
            let requested: Bool
            let limit: Int
            let lines: [String]
            let lineCount: Int
            let truncated: Bool
            let source: String?

            init(
                requested: Bool,
                limit: Int,
                lines: [String],
                lineCount: Int? = nil,
                truncated: Bool = false,
                source: String? = nil
            ) {
                self.requested = requested
                self.limit = limit
                self.lines = lines
                self.lineCount = lineCount ?? lines.count
                self.truncated = truncated
                self.source = source
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                requested = try container.decode(Bool.self, forKey: .requested)
                limit = try container.decode(Int.self, forKey: .limit)
                lines = try container.decode([String].self, forKey: .lines)
                lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount) ?? lines.count
                truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
                source = try container.decodeIfPresent(String.self, forKey: .source)
            }

            private enum CodingKeys: String, CodingKey {
                case requested, limit, lines, truncated, source
                case lineCount = "line_count"
            }
        }

        struct MergeDTO: Codable, Equatable {
            let status: String
            let operationID: String?
            let sessionID: String?
            let source: EndpointDTO?
            let target: EndpointDTO?
            let mergeBase: String?
            let sourceHead: String?
            let targetHeadBefore: String?
            let targetHeadAfter: String?
            let mergeCommit: String?
            let visualization: VisualizationDTO?
            let preflight: PreflightDTO?
            let summary: SummaryDTO?
            let artifacts: ArtifactsDTO?
            let conflictFiles: [String]?
            let staleReason: String?
            let errorCode: String?
            let error: String?
            let postMerge: String?
            let sourceWorktreeStatus: String?
            let nextActions: [String]

            init(
                status: String,
                operationID: String? = nil,
                sessionID: String? = nil,
                source: EndpointDTO? = nil,
                target: EndpointDTO? = nil,
                mergeBase: String? = nil,
                sourceHead: String? = nil,
                targetHeadBefore: String? = nil,
                targetHeadAfter: String? = nil,
                mergeCommit: String? = nil,
                visualization: VisualizationDTO? = nil,
                preflight: PreflightDTO? = nil,
                summary: SummaryDTO? = nil,
                artifacts: ArtifactsDTO? = nil,
                conflictFiles: [String]? = nil,
                staleReason: String? = nil,
                errorCode: String? = nil,
                error: String? = nil,
                postMerge: String? = nil,
                sourceWorktreeStatus: String? = nil,
                nextActions: [String] = []
            ) {
                self.status = status
                self.operationID = operationID
                self.sessionID = sessionID
                self.source = source
                self.target = target
                self.mergeBase = mergeBase
                self.sourceHead = sourceHead
                self.targetHeadBefore = targetHeadBefore
                self.targetHeadAfter = targetHeadAfter
                self.mergeCommit = mergeCommit
                self.visualization = visualization
                self.preflight = preflight
                self.summary = summary
                self.artifacts = artifacts
                self.conflictFiles = conflictFiles
                self.staleReason = staleReason
                self.errorCode = errorCode
                self.error = error
                self.postMerge = postMerge
                self.sourceWorktreeStatus = sourceWorktreeStatus
                self.nextActions = nextActions
            }

            private enum CodingKeys: String, CodingKey {
                case status, source, target, visualization, preflight, summary, artifacts, error
                case operationID = "operation_id"
                case sessionID = "session_id"
                case mergeBase = "merge_base"
                case sourceHead = "source_head"
                case targetHeadBefore = "target_head_before"
                case targetHeadAfter = "target_head_after"
                case mergeCommit = "merge_commit"
                case conflictFiles = "conflict_files"
                case staleReason = "stale_reason"
                case errorCode = "error_code"
                case postMerge = "post_merge"
                case sourceWorktreeStatus = "source_worktree_status"
                case nextActions = "next_actions"
            }

            struct EndpointDTO: Codable, Equatable {
                let worktreeID: String
                let repoKey: String
                let path: String
                let name: String?
                let branch: String?
                let head: String
                let shortHead: String
                let isMain: Bool
                let label: String

                private enum CodingKeys: String, CodingKey {
                    case worktreeID = "worktree_id"
                    case repoKey = "repo_key"
                    case path, name, branch, head
                    case shortHead = "short_head"
                    case isMain = "is_main"
                    case label
                }
            }

            struct VisualizationDTO: Codable, Equatable {
                let requested: Bool
                let limit: Int
                let text: String
                let lines: [String]
                let lineCount: Int
                let truncated: Bool
                let sourceWorktreeID: String?
                let targetWorktreeID: String?
                let source: String?

                init(
                    requested: Bool,
                    limit: Int,
                    text: String,
                    lines: [String],
                    lineCount: Int? = nil,
                    truncated: Bool = false,
                    sourceWorktreeID: String? = nil,
                    targetWorktreeID: String? = nil,
                    source: String? = nil
                ) {
                    self.requested = requested
                    self.limit = limit
                    self.text = text
                    self.lines = lines
                    self.lineCount = lineCount ?? lines.count
                    self.truncated = truncated
                    self.sourceWorktreeID = sourceWorktreeID
                    self.targetWorktreeID = targetWorktreeID
                    self.source = source
                }

                private enum CodingKeys: String, CodingKey {
                    case requested, limit, text, lines, truncated, source
                    case lineCount = "line_count"
                    case sourceWorktreeID = "source_worktree_id"
                    case targetWorktreeID = "target_worktree_id"
                }
            }

            struct PreflightDTO: Codable, Equatable {
                let blocked: Bool
                let blockers: [BlockerDTO]
                let conflictPrediction: ConflictPredictionDTO?

                private enum CodingKeys: String, CodingKey {
                    case blocked, blockers
                    case conflictPrediction = "conflict_prediction"
                }
            }

            struct BlockerDTO: Codable, Equatable {
                let code: String
                let message: String
                let paths: [String]
            }

            struct ConflictPredictionDTO: Codable, Equatable {
                let status: String
                let files: [String]
                let message: String?
            }

            struct SummaryDTO: Codable, Equatable {
                let commits: Int
                let files: Int
                let insertions: Int
                let deletions: Int
            }

            struct ArtifactsDTO: Codable, Equatable {
                let snapshotID: String
                let snapshotDirectory: String
                let manifestPath: String
                let mapPath: String
                let allPatchPath: String?
                let sidecarPath: String

                private enum CodingKeys: String, CodingKey {
                    case snapshotID = "snapshot_id"
                    case snapshotDirectory = "snapshot_directory"
                    case manifestPath = "manifest_path"
                    case mapPath = "map_path"
                    case allPatchPath = "all_patch_path"
                    case sidecarPath = "sidecar_path"
                }
            }
        }
    }

    // MARK: - Unified Git Tool

    /// Main reply DTO for the unified `git` MCP tool.
    /// The `op` field indicates which operation was performed and which
    /// payload fields are populated.
    ///
    /// Multi-root support:
    /// - When operating on a single repo, the existing flat structure is used (status, diff, log, etc.)
    /// - When operating on multiple repos, the `repos` array contains per-repo results
    /// - The `aggregate` field contains combined totals across all repos (for multi-root diff)
    struct GitToolReplyDTO: Codable, Equatable {
        let op: String

        /// Multi-root support
        /// Per-repo results for multi-root operations (nil when single repo)
        let repos: [RepoResultDTO]?
        /// Aggregated results across all repos (for multi-root diff operations)
        let aggregate: AggregateDTO?

        /// Status op payload (single repo)
        let status: StatusDTO?

        /// Diff op payload (single repo)
        let diff: DiffDTO?

        /// Log op payload (single repo)
        let log: LogDTO?

        /// Show op payload (single repo)
        let show: ShowDTO?

        /// Blame op payload (single repo)
        let blame: BlameDTO?

        /// Worktree metadata (single repo)
        let worktree: WorktreeDTO?

        // Artifact info (diff with artifacts: true)
        let snapshotId: String?
        let snapshotDir: String?

        let artifacts: ArtifactsDTO?
        let primaryArtifacts: PrimaryArtifactsDTO?
        let summary: SummaryDTO?
        let oneliner: String?
        let inputs: DiffInputsDTO?
        let modeDetails: String?
        let inline: InlineDTO?

        // Common
        let warning: String?
        let emptyReason: String?
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case op, repos, aggregate, status, diff, log, show, blame, worktree
            case artifacts, summary, oneliner, inputs, inline, warning, error
            case primaryArtifacts = "primary_artifacts"
            case snapshotId = "snapshot_id"
            case snapshotDir = "snapshot_dir"

            case modeDetails = "mode_details"
            case emptyReason = "empty_reason"
        }

        /// Explicit initializer to allow default values for new optional fields
        init(
            op: String,
            repos: [RepoResultDTO]? = nil,
            aggregate: AggregateDTO? = nil,
            status: StatusDTO? = nil,
            diff: DiffDTO? = nil,
            log: LogDTO? = nil,
            show: ShowDTO? = nil,
            blame: BlameDTO? = nil,
            worktree: WorktreeDTO? = nil,
            snapshotId: String? = nil,
            snapshotDir: String? = nil,
            artifacts: ArtifactsDTO? = nil,
            primaryArtifacts: PrimaryArtifactsDTO? = nil,
            summary: SummaryDTO? = nil,
            oneliner: String? = nil,
            inputs: DiffInputsDTO? = nil,
            modeDetails: String? = nil,
            inline: InlineDTO? = nil,
            warning: String? = nil,
            emptyReason: String? = nil,
            error: String? = nil
        ) {
            self.op = op
            self.repos = repos
            self.aggregate = aggregate
            self.status = status
            self.diff = diff
            self.log = log
            self.show = show
            self.blame = blame
            self.worktree = worktree
            self.snapshotId = snapshotId
            self.snapshotDir = snapshotDir
            self.artifacts = artifacts
            self.primaryArtifacts = primaryArtifacts
            self.summary = summary
            self.oneliner = oneliner
            self.inputs = inputs
            self.modeDetails = modeDetails
            self.inline = inline
            self.warning = warning
            self.emptyReason = emptyReason
            self.error = error
        }

        // MARK: - Nested DTOs

        // MARK: Multi-root DTOs

        /// Per-repo result for multi-root operations
        struct RepoResultDTO: Codable, Equatable {
            /// Canonical absolute path of the git repository root
            let repoRoot: String
            /// Stable repo key for storage/identification
            let repoKey: String
            /// Human-readable repo name (typically last path component)
            let repoName: String?

            // Op-specific payloads (at most one populated per repo)
            let status: StatusDTO?
            let diff: DiffDTO?
            let log: LogDTO?
            let show: ShowDTO?
            let blame: BlameDTO?

            /// Worktree metadata (per repo)
            let worktree: WorktreeDTO?

            // Artifact info (for diff with artifacts)
            let snapshotId: String?
            let snapshotDir: String?
            let artifacts: ArtifactsDTO?
            let primaryArtifacts: PrimaryArtifactsDTO?
            let summary: SummaryDTO?
            let oneliner: String?
            let inputs: DiffInputsDTO?
            let modeDetails: String?
            let inline: InlineDTO?

            // Per-repo status
            let warning: String?
            let emptyReason: String?
            let error: String?

            private enum CodingKeys: String, CodingKey {
                case repoRoot = "repo_root"
                case repoKey = "repo_key"
                case repoName = "repo_name"
                case status, diff, log, show, blame, worktree
                case snapshotId = "snapshot_id"
                case snapshotDir = "snapshot_dir"
                case artifacts, summary, oneliner, inputs
                case primaryArtifacts = "primary_artifacts"
                case modeDetails = "mode_details"
                case inline
                case warning
                case emptyReason = "empty_reason"
                case error
            }

            init(
                repoRoot: String,
                repoKey: String,
                repoName: String? = nil,
                status: StatusDTO? = nil,
                diff: DiffDTO? = nil,
                log: LogDTO? = nil,
                show: ShowDTO? = nil,
                blame: BlameDTO? = nil,
                worktree: WorktreeDTO? = nil,
                snapshotId: String? = nil,
                snapshotDir: String? = nil,
                artifacts: ArtifactsDTO? = nil,
                primaryArtifacts: PrimaryArtifactsDTO? = nil,
                summary: SummaryDTO? = nil,
                oneliner: String? = nil,
                inputs: DiffInputsDTO? = nil,
                modeDetails: String? = nil,
                inline: InlineDTO? = nil,
                warning: String? = nil,
                emptyReason: String? = nil,
                error: String? = nil
            ) {
                self.repoRoot = repoRoot
                self.repoKey = repoKey
                self.repoName = repoName
                self.status = status
                self.diff = diff
                self.log = log
                self.show = show
                self.blame = blame
                self.worktree = worktree
                self.snapshotId = snapshotId
                self.snapshotDir = snapshotDir
                self.artifacts = artifacts
                self.primaryArtifacts = primaryArtifacts
                self.summary = summary
                self.oneliner = oneliner
                self.inputs = inputs
                self.modeDetails = modeDetails
                self.inline = inline
                self.warning = warning
                self.emptyReason = emptyReason
                self.error = error
            }
        }

        /// Aggregated results across multiple repos (for multi-root diff)
        struct AggregateDTO: Codable, Equatable {
            /// Combined totals across all repos
            let totals: TotalsDTO?
            /// Combined status breakdown across all repos
            let byStatus: [String: Int]?
            /// Summary one-liner (e.g., "3 repos: 15 files (+200 -50)")
            let oneliner: String?
            /// Number of repos included in aggregation
            let repoCount: Int?

            init(
                totals: TotalsDTO? = nil,
                byStatus: [String: Int]? = nil,
                oneliner: String? = nil,
                repoCount: Int? = nil
            ) {
                self.totals = totals
                self.byStatus = byStatus
                self.oneliner = oneliner
                self.repoCount = repoCount
            }

            private enum CodingKeys: String, CodingKey {
                case totals
                case byStatus = "by_status"
                case oneliner
                case repoCount = "repo_count"
            }
        }

        struct WorktreeDTO: Codable, Equatable {
            let isWorktree: Bool
            let worktreeName: String?
            let worktreeRoot: String
            let commonGitDir: String?
            let mainWorktreeRoot: String?
            let worktreeBranch: String?
            let mainBranch: String?
            let worktreeHead: String?
            let mainHead: String?

            private enum CodingKeys: String, CodingKey {
                case isWorktree = "is_worktree"
                case worktreeName = "worktree_name"
                case worktreeRoot = "worktree_root"
                case commonGitDir = "common_git_dir"
                case mainWorktreeRoot = "main_worktree_root"
                case worktreeBranch = "worktree_branch"
                case mainBranch = "main_branch"
                case worktreeHead = "worktree_head"
                case mainHead = "main_head"
            }
        }

        struct StatusDTO: Codable, Equatable {
            let branch: String?
            let upstream: String?
            let ahead: Int?
            let behind: Int?
            let staged: [String]
            let modified: [String]
            let untracked: [String]
            let summary: String

            private enum CodingKeys: String, CodingKey {
                case branch, upstream, ahead, behind, staged, modified, untracked, summary
            }
        }

        struct DiffDTO: Codable, Equatable {
            let compare: String
            let detail: String?
            let files: [DiffFileDTO]?
            let totals: TotalsDTO
            let byStatus: [String: Int]?
            let oneliner: String
            let truncated: Bool?
            let truncationNote: String?

            private enum CodingKeys: String, CodingKey {
                case compare, detail, files, totals, oneliner, truncated
                case byStatus = "by_status"
                case truncationNote = "truncation_note"
            }
        }

        struct DiffFileDTO: Codable, Equatable {
            let path: String
            let status: String
            let insertions: Int?
            let deletions: Int?
            let hunks: [DiffHunkDTO]?

            private enum CodingKeys: String, CodingKey {
                case path, status, insertions, deletions, hunks
            }
        }

        struct DiffHunkDTO: Codable, Equatable {
            let header: String
            let oldStart: Int
            let newStart: Int
            let patch: String

            private enum CodingKeys: String, CodingKey {
                case header, patch
                case oldStart = "old_start"
                case newStart = "new_start"
            }
        }

        struct TotalsDTO: Codable, Equatable {
            let files: Int
            let insertions: Int
            let deletions: Int
        }

        struct LogDTO: Codable, Equatable {
            let commits: [CommitSummaryDTO]
        }

        struct CommitSummaryDTO: Codable, Equatable {
            let sha: String
            let shortSha: String
            let author: String
            let date: String
            let message: String
            let filesChanged: Int
            let insertions: Int
            let deletions: Int

            private enum CodingKeys: String, CodingKey {
                case sha, author, date, message, insertions, deletions
                case shortSha = "short_sha"
                case filesChanged = "files_changed"
            }
        }

        struct ShowDTO: Codable, Equatable {
            let sha: String
            let shortSha: String
            let author: String
            let date: String
            let message: String
            let files: [DiffFileDTO]?
            let totals: TotalsDTO
            let hunks: [DiffHunkDTO]?

            private enum CodingKeys: String, CodingKey {
                case sha, author, date, message, files, totals, hunks
                case shortSha = "short_sha"
            }
        }

        struct BlameDTO: Codable, Equatable {
            let path: String
            let lines: [BlameLineDTO]
        }

        struct BlameLineDTO: Codable, Equatable {
            let num: Int
            let sha: String
            let author: String
            let date: String
            let content: String
        }

        struct SummaryDTO: Codable, Equatable {
            let files: Int
            let insertions: Int
            let deletions: Int
            let byStatus: [String: Int]?

            private enum CodingKeys: String, CodingKey {
                case files, insertions, deletions
                case byStatus = "by_status"
            }
        }

        struct ArtifactsDTO: Codable, Equatable {
            let manifest: String
            let map: String
            let filesTsv: String
            let changedLines: String?
            let tree: String
            let selectionPaths: String?
            let allPatch: String?
            let deepHunks: String?
            let deepChangedLines: String?

            private enum CodingKeys: String, CodingKey {
                case manifest, map, tree
                case filesTsv = "files_tsv"
                case changedLines = "changed_lines"
                case selectionPaths = "selection_paths"
                case allPatch = "all_patch"
                case deepHunks = "deep_hunks"
                case deepChangedLines = "deep_changed_lines"
            }
        }

        struct PrimaryArtifactsDTO: Codable, Equatable {
            struct PerFilePatchDTO: Codable, Equatable {
                let jumpIndex: Int
                let gitPath: String
                let selectionPath: String
                let status: String?
                let additions: Int?
                let deletions: Int?

                private enum CodingKeys: String, CodingKey {
                    case status, additions, deletions
                    case jumpIndex = "jump_index"
                    case gitPath = "git_path"
                    case selectionPath = "selection_path"
                }
            }

            let map: String
            let allPatch: String?
            let autoSelected: [String]?
            let perFilePatches: [PerFilePatchDTO]?

            private enum CodingKeys: String, CodingKey {
                case map
                case allPatch = "all_patch"
                case autoSelected = "auto_selected"
                case perFilePatches = "per_file_patches"
            }
        }

        struct InlineDTO: Codable, Equatable {
            let mapExcerpt: String
            let truncated: Bool
            let totalLines: Int
            let returnedLines: Int

            private enum CodingKeys: String, CodingKey {
                case mapExcerpt = "map_excerpt"
                case truncated
                case totalLines = "total_lines"
                case returnedLines = "returned_lines"
            }
        }

        struct DiffInputsDTO: Codable, Equatable {
            let compare: String
            let compareInput: String?
            let scope: String
            let requestedPathsCount: Int?
            let contextLines: Int
            let detectRenames: Bool

            private enum CodingKeys: String, CodingKey {
                case compare, scope
                case compareInput = "compare_input"
                case requestedPathsCount = "requested_paths_count"
                case contextLines = "context_lines"
                case detectRenames = "detect_renames"
            }
        }
    }

    // MARK: - Git Diff (legacy)

    struct GitDiffPublishReplyDTO: Codable, Equatable {
        let op: String
        let snapshotId: String?
        let snapshotDir: String?
        let artifacts: ArtifactsDTO?
        let summary: SummaryDTO?
        let oneliner: String?
        let inputs: InputsDTO?
        let modeDetails: String?
        let warning: String?
        let emptyReason: String?
        let inline: InlineDTO?
        let snapshots: [SnapshotEntryDTO]?
        let deleted: [String]?
        let notFound: [String]?

        struct ArtifactsDTO: Codable, Equatable {
            let manifest: String
            let map: String
            let filesTsv: String
            let changedLines: String?
            let tree: String
            let selectionPaths: String?
            let allPatch: String?
            let deepHunks: String?
            let deepChangedLines: String?

            private enum CodingKeys: String, CodingKey {
                case manifest
                case map
                case filesTsv = "files_tsv"
                case changedLines = "changed_lines"
                case tree
                case selectionPaths = "selection_paths"
                case allPatch = "all_patch"
                case deepHunks = "deep_hunks"
                case deepChangedLines = "deep_changed_lines"
            }
        }

        struct SummaryDTO: Codable, Equatable {
            let files: Int
            let insertions: Int
            let deletions: Int
            let byStatus: [String: Int]?

            private enum CodingKeys: String, CodingKey {
                case files
                case insertions
                case deletions
                case byStatus = "by_status"
            }
        }

        struct InputsDTO: Codable, Equatable {
            let compare: String
            let compareInput: String?
            let scope: String
            let requestedPathsCount: Int?
            let contextLines: Int
            let detectRenames: Bool

            private enum CodingKeys: String, CodingKey {
                case compare
                case compareInput = "compare_input"
                case scope
                case requestedPathsCount = "requested_paths_count"
                case contextLines = "context_lines"
                case detectRenames = "detect_renames"
            }
        }

        struct SnapshotEntryDTO: Codable, Equatable {
            let snapshotId: String
            let repoKey: String?
            let snapshotDir: String?
            let generatedAt: String
            let mode: String
            let compare: String
            let scope: String
            let summary: SummaryDTO
            let oneliner: String?
            let current: Bool?

            private enum CodingKeys: String, CodingKey {
                case snapshotId = "snapshot_id"
                case repoKey = "repo_key"
                case snapshotDir = "snapshot_dir"
                case generatedAt = "generated_at"
                case mode
                case compare
                case scope
                case summary
                case oneliner
                case current
            }
        }

        struct InlineDTO: Codable, Equatable {
            let mapExcerpt: String
            let truncated: Bool
            let totalLines: Int
            let returnedLines: Int

            private enum CodingKeys: String, CodingKey {
                case mapExcerpt = "map_excerpt"
                case truncated
                case totalLines = "total_lines"
                case returnedLines = "returned_lines"
            }
        }
    }

    /// Envelope for prompt tool results (discriminated by `op` field)
    struct PromptToolEnvelope: Codable, Equatable {
        let op: String
        let prompt: PromptReply?
        let export: PromptExportReply?
        let presetsList: PresetsListReply?
        let selectedPreset: CopyPresetDescriptorDTO?

        private enum CodingKeys: String, CodingKey {
            case op
            case prompt
            case export
            case presetsList = "presets_list"
            case selectedPreset = "selected_preset"
        }

        static func forPrompt(_ reply: PromptReply, op: String) -> PromptToolEnvelope {
            PromptToolEnvelope(op: op, prompt: reply, export: nil, presetsList: nil, selectedPreset: nil)
        }

        static func forExport(_ reply: PromptExportReply) -> PromptToolEnvelope {
            PromptToolEnvelope(op: "export", prompt: nil, export: reply, presetsList: nil, selectedPreset: nil)
        }

        static func forPresetsList(_ presets: [CopyPresetListItemDTO]) -> PromptToolEnvelope {
            PromptToolEnvelope(op: "list_presets", prompt: nil, export: nil, presetsList: PresetsListReply(presets: presets), selectedPreset: nil)
        }

        static func forSelectPreset(_ preset: CopyPresetDescriptorDTO) -> PromptToolEnvelope {
            PromptToolEnvelope(op: "select_preset", prompt: nil, export: nil, presetsList: nil, selectedPreset: preset)
        }
    }

    /// Unified prompt-context payload for `workspace_context`
    struct PromptContextDTO: Codable, Equatable {
        let prompt: String
        let selection: SelectedFilesReply?
        /// When requested, raw content blocks (from selected files)
        let fileBlocks: [String]?
        /// When requested (default), the codemap aggregation + unmapped files
        let codeStructure: SelectedCodeStructureDTO?
        /// Optional selected file tree
        let fileTree: FileTreeDTO?
        /// Optional token stats (normalized/agent view - always includes codemaps)
        let tokenStats: TokenStats?
        /// Token stats matching user's copy preset settings (codemaps may be disabled)
        let userTokenStats: TokenStats?
        /// Explains why tokenStats and userTokenStats differ (e.g., codemap settings)
        let tokenStatsNote: String?
        /// Active and effective copy preset information (when override is used)
        let copyPreset: CopyPresetContextDTO?
        /// Available copy presets (when include contains "presets")
        let copyPresets: [CopyPresetListItemDTO]?
        /// Active logical→effective worktree scope for filesystem-derived context.
        let worktreeScope: WorktreeScopeDTO?

        init(
            prompt: String,
            selection: SelectedFilesReply?,
            fileBlocks: [String]?,
            codeStructure: SelectedCodeStructureDTO?,
            fileTree: FileTreeDTO?,
            tokenStats: TokenStats?,
            userTokenStats: TokenStats?,
            tokenStatsNote: String?,
            copyPreset: CopyPresetContextDTO?,
            copyPresets: [CopyPresetListItemDTO]?,
            worktreeScope: WorktreeScopeDTO? = nil
        ) {
            self.prompt = prompt
            self.selection = selection
            self.fileBlocks = fileBlocks
            self.codeStructure = codeStructure
            self.fileTree = fileTree
            self.tokenStats = tokenStats
            self.userTokenStats = userTokenStats
            self.tokenStatsNote = tokenStatsNote
            self.copyPreset = copyPreset
            self.copyPresets = copyPresets
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case prompt
            case selection
            case fileBlocks = "file_blocks"
            case codeStructure = "code_structure"
            case fileTree = "file_tree"
            case tokenStats = "token_stats"
            case userTokenStats = "user_token_stats"
            case tokenStatsNote = "token_stats_note"
            case copyPreset = "copy_preset"
            case copyPresets = "copy_presets"
            case worktreeScope = "worktree_scope"
        }
    }
}
