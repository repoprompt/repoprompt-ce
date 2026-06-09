import Foundation

package struct WorkspaceSelectionProjection: Equatable {
    package enum BaseMode: Equatable {
        case full
        case slice
        case codemap
    }

    package enum RenderMode: Equatable {
        case full
        case slice
        case codemap
        case hidden
    }

    package enum CodemapOrigin: Equatable {
        case auto
        case manual
        case selectedMode
        case completeMode
    }

    package struct PathMetadata: Equatable {
        package let displayPath: String
        package let rootPath: String
        package let pathWithinRoot: String

        package init(displayPath: String, rootPath: String, pathWithinRoot: String) {
            self.displayPath = displayPath
            self.rootPath = rootPath
            self.pathWithinRoot = pathWithinRoot
        }
    }

    package struct FileAlternate: Equatable {
        package let mode: RenderMode
        package let tokens: Int
        package let codemapOrigin: CodemapOrigin?

        package init(mode: RenderMode, tokens: Int, codemapOrigin: CodemapOrigin?) {
            self.mode = mode
            self.tokens = tokens
            self.codemapOrigin = codemapOrigin
        }
    }

    package struct File: Equatable {
        package let file: WorkspaceFileRecord
        package let metadata: PathMetadata
        package let mode: RenderMode
        package let ranges: [LineRange]?
        package let tokens: Int
        package let codemapAvailable: Bool
        package let codemapOrigin: CodemapOrigin?
        package let alternate: FileAlternate?

        package var isAuto: Bool {
            codemapOrigin == .auto
        }

        package init(
            file: WorkspaceFileRecord,
            metadata: PathMetadata,
            mode: RenderMode,
            ranges: [LineRange]?,
            tokens: Int,
            codemapAvailable: Bool,
            codemapOrigin: CodemapOrigin?,
            alternate: FileAlternate?
        ) {
            self.file = file
            self.metadata = metadata
            self.mode = mode
            self.ranges = ranges
            self.tokens = tokens
            self.codemapAvailable = codemapAvailable
            self.codemapOrigin = codemapOrigin
            self.alternate = alternate
        }
    }

    package struct Slice: Equatable {
        package let file: WorkspaceFileRecord
        package let metadata: PathMetadata
        package let ranges: [LineRange]

        package init(file: WorkspaceFileRecord, metadata: PathMetadata, ranges: [LineRange]) {
            self.file = file
            self.metadata = metadata
            self.ranges = ranges
        }
    }

    package struct Summary: Equatable {
        package let fullCount: Int
        package let sliceCount: Int
        package let codemapCount: Int
        package let fullTokens: Int
        package let sliceTokens: Int
        package let codemapTokens: Int

        package var totalCount: Int {
            fullCount + sliceCount + codemapCount
        }

        package var totalTokens: Int {
            fullTokens + sliceTokens + codemapTokens
        }

        package init(
            fullCount: Int,
            sliceCount: Int,
            codemapCount: Int,
            fullTokens: Int,
            sliceTokens: Int,
            codemapTokens: Int
        ) {
            self.fullCount = fullCount
            self.sliceCount = sliceCount
            self.codemapCount = codemapCount
            self.fullTokens = fullTokens
            self.sliceTokens = sliceTokens
            self.codemapTokens = codemapTokens
        }

        package static let empty = Summary(
            fullCount: 0,
            sliceCount: 0,
            codemapCount: 0,
            fullTokens: 0,
            sliceTokens: 0,
            codemapTokens: 0
        )
    }

    package struct IncludedFile: Equatable {
        package let file: WorkspaceFileRecord
        package let metadata: PathMetadata
        package let mode: RenderMode
        package let ranges: [LineRange]?
        package let tokens: Int
        package let fullTokens: Int?
        package let codemapTokens: Int
        package let codemapOrigin: CodemapOrigin?
        package let codemapContent: String?

        package init(
            file: WorkspaceFileRecord,
            metadata: PathMetadata,
            mode: RenderMode,
            ranges: [LineRange]?,
            tokens: Int,
            fullTokens: Int?,
            codemapTokens: Int,
            codemapOrigin: CodemapOrigin?,
            codemapContent: String?
        ) {
            self.file = file
            self.metadata = metadata
            self.mode = mode
            self.ranges = ranges
            self.tokens = tokens
            self.fullTokens = fullTokens
            self.codemapTokens = codemapTokens
            self.codemapOrigin = codemapOrigin
            self.codemapContent = codemapContent
        }
    }

    package struct Alternate: Equatable {
        package let codeMapUsage: CodeMapUsage
        package let includesFiles: Bool
        package let contentTokens: Int
        package let codemapTokens: Int
        package let totalTokens: Int
        package let includedTotalTokens: Int
        package let includedFiles: [IncludedFile]

        package init(
            codeMapUsage: CodeMapUsage,
            includesFiles: Bool,
            contentTokens: Int,
            codemapTokens: Int,
            totalTokens: Int,
            includedTotalTokens: Int,
            includedFiles: [IncludedFile] = []
        ) {
            self.codeMapUsage = codeMapUsage
            self.includesFiles = includesFiles
            self.contentTokens = contentTokens
            self.codemapTokens = codemapTokens
            self.totalTokens = totalTokens
            self.includedTotalTokens = includedTotalTokens
            self.includedFiles = includedFiles
        }
    }

    package let files: [File]
    package let normalizedFiles: [IncludedFile]
    package let slices: [Slice]
    package let summary: Summary
    package let invalidPaths: [String]
    package let codeMapUsage: CodeMapUsage
    package let codemapAutoEnabled: Bool
    package let alternate: Alternate?

    package var totalTokens: Int {
        summary.totalTokens
    }

    package init(
        files: [File],
        normalizedFiles: [IncludedFile] = [],
        slices: [Slice],
        summary: Summary,
        invalidPaths: [String],
        codeMapUsage: CodeMapUsage,
        codemapAutoEnabled: Bool,
        alternate: Alternate?
    ) {
        self.files = files
        self.normalizedFiles = normalizedFiles
        self.slices = slices
        self.summary = summary
        self.invalidPaths = invalidPaths
        self.codeMapUsage = codeMapUsage
        self.codemapAutoEnabled = codemapAutoEnabled
        self.alternate = alternate
    }
}

package struct WorkspaceSelectionProjectionRequest: Equatable {
    package struct TokenFacts: Equatable {
        package let displayTokens: Int
        package let fullTokens: Int
        package let codemapTokens: Int

        package init(displayTokens: Int, fullTokens: Int, codemapTokens: Int) {
            self.displayTokens = displayTokens
            self.fullTokens = fullTokens
            self.codemapTokens = codemapTokens
        }
    }

    package struct Entry: Equatable {
        package let file: WorkspaceFileRecord
        package let metadata: WorkspaceSelectionProjection.PathMetadata
        package let mode: WorkspaceSelectionProjection.BaseMode
        package let ranges: [LineRange]
        package let tokens: TokenFacts
        package let codemapAvailable: Bool
        package let codemapContent: String?

        package init(
            file: WorkspaceFileRecord,
            metadata: WorkspaceSelectionProjection.PathMetadata,
            mode: WorkspaceSelectionProjection.BaseMode,
            ranges: [LineRange] = [],
            tokens: TokenFacts,
            codemapAvailable: Bool,
            codemapContent: String? = nil
        ) {
            self.file = file
            self.metadata = metadata
            self.mode = mode
            self.ranges = ranges
            self.tokens = tokens
            self.codemapAvailable = codemapAvailable
            self.codemapContent = codemapContent
        }
    }

    package struct AlternatePolicy: Equatable {
        package let includeFiles: Bool
        package let codeMapUsage: CodeMapUsage

        package init(includeFiles: Bool, codeMapUsage: CodeMapUsage) {
            self.includeFiles = includeFiles
            self.codeMapUsage = codeMapUsage
        }
    }

    package let entries: [Entry]
    package let completeAlternateEntries: [Entry]
    package let codeMapUsage: CodeMapUsage
    package let codemapAutoEnabled: Bool
    package let missingPaths: [String]
    package let invalidPaths: [String]
    package let alternatePolicy: AlternatePolicy?

    package init(
        entries: [Entry],
        completeAlternateEntries: [Entry] = [],
        codeMapUsage: CodeMapUsage,
        codemapAutoEnabled: Bool,
        missingPaths: [String] = [],
        invalidPaths: [String] = [],
        alternatePolicy: AlternatePolicy? = nil
    ) {
        self.entries = entries
        self.completeAlternateEntries = completeAlternateEntries
        self.codeMapUsage = codeMapUsage
        self.codemapAutoEnabled = codemapAutoEnabled
        self.missingPaths = missingPaths
        self.invalidPaths = invalidPaths
        self.alternatePolicy = alternatePolicy
    }
}
