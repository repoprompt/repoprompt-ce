import Foundation

package struct WorkspaceContextProjection: Equatable {
    package struct Section<Value: Equatable & Sendable>: Equatable {
        package let provenance: WorkspaceFileContextCapture.Provenance
        package let value: Value

        package init(provenance: WorkspaceFileContextCapture.Provenance, value: Value) {
            self.provenance = provenance
            self.value = value
        }
    }

    package struct FileTree: Equatable {
        package let rootCount: Int
        package let usesLegend: Bool
        package let content: String

        package init(rootCount: Int, usesLegend: Bool, content: String) {
            self.rootCount = rootCount
            self.usesLegend = usesLegend
            self.content = content
        }
    }

    package struct TokenViews: Equatable {
        package let normalized: TokenProjection
        package let userConfigured: TokenProjection?

        package init(normalized: TokenProjection, userConfigured: TokenProjection?) {
            self.normalized = normalized
            self.userConfigured = userConfigured
        }
    }

    package let prompt: Section<String>?
    package let selection: Section<WorkspaceSelectionProjection>?
    package let fileBlocks: Section<[String]>?
    package let codeStructure: Section<CodeStructureProjection>?
    package let fileTree: Section<FileTree>?
    package let tokens: Section<TokenViews>?

    package init(
        prompt: Section<String>?,
        selection: Section<WorkspaceSelectionProjection>?,
        fileBlocks: Section<[String]>?,
        codeStructure: Section<CodeStructureProjection>?,
        fileTree: Section<FileTree>?,
        tokens: Section<TokenViews>?
    ) {
        self.prompt = prompt
        self.selection = selection
        self.fileBlocks = fileBlocks
        self.codeStructure = codeStructure
        self.fileTree = fileTree
        self.tokens = tokens
    }
}

package enum WorkspaceTokenProjectionInput: Equatable {
    case componentEstimate(
        source: TokenProjection.Source,
        nonFile: TokenProjectionService.WorkspaceNonFileComponents
    )
    case activeLive(TokenProjectionService.ActiveLiveWorkspaceInput)

    package static let emptyVirtual = WorkspaceTokenProjectionInput.componentEstimate(
        source: .virtualRecomputed,
        nonFile: .init(prompt: 0, fileTree: 0, meta: 0, git: 0)
    )
}

package struct WorkspaceContextProjectionRequest: Equatable {
    package struct Sections: OptionSet, Equatable {
        package let rawValue: Int

        package init(rawValue: Int) {
            self.rawValue = rawValue
        }

        package static let prompt = Sections(rawValue: 1 << 0)
        package static let selection = Sections(rawValue: 1 << 1)
        package static let files = Sections(rawValue: 1 << 2)
        package static let codeStructure = Sections(rawValue: 1 << 3)
        package static let fileTree = Sections(rawValue: 1 << 4)
        package static let tokens = Sections(rawValue: 1 << 5)
        package static let all: Sections = [.prompt, .selection, .files, .codeStructure, .fileTree, .tokens]
    }

    package let sections: Sections
    package let promptText: String
    package let filePathDisplay: FilePathDisplay
    package let codeMapUsage: CodeMapUsage
    package let alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy?
    package let codeStructureBudget: CodeStructureProjectionRequest.Budget
    package let includeUnmappedCodeStructurePaths: Bool
    package let tokenProjectionInput: WorkspaceTokenProjectionInput

    package init(
        sections: Sections = .all,
        promptText: String = "",
        filePathDisplay: FilePathDisplay = .relative,
        codeMapUsage: CodeMapUsage = .auto,
        alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy? = nil,
        codeStructureBudget: CodeStructureProjectionRequest.Budget = .init(resultLimit: 25),
        includeUnmappedCodeStructurePaths: Bool = true,
        tokenProjectionInput: WorkspaceTokenProjectionInput = .emptyVirtual
    ) {
        self.sections = sections
        self.promptText = promptText
        self.filePathDisplay = filePathDisplay
        self.codeMapUsage = codeMapUsage
        self.alternatePolicy = alternatePolicy
        self.codeStructureBudget = codeStructureBudget
        self.includeUnmappedCodeStructurePaths = includeUnmappedCodeStructurePaths
        self.tokenProjectionInput = tokenProjectionInput
    }
}

package struct WorkspaceContextProjectionPlan {
    package struct Occurrence {
        package let value: WorkspaceContextProjectionMaterializationRequest.Occurrence
        package let fileAPI: FileAPI?

        package init(
            value: WorkspaceContextProjectionMaterializationRequest.Occurrence,
            fileAPI: FileAPI?
        ) {
            self.value = value
            self.fileAPI = fileAPI
        }
    }

    package let provenance: WorkspaceFileContextCapture.Provenance
    package let occurrences: [Occurrence]
    package let completeAlternateOccurrences: [Occurrence]
    package let missingPaths: [String]
    package let invalidPaths: [String]

    package init(
        provenance: WorkspaceFileContextCapture.Provenance,
        occurrences: [Occurrence],
        completeAlternateOccurrences: [Occurrence],
        missingPaths: [String],
        invalidPaths: [String]
    ) {
        self.provenance = provenance
        self.occurrences = occurrences
        self.completeAlternateOccurrences = completeAlternateOccurrences
        self.missingPaths = missingPaths
        self.invalidPaths = invalidPaths
    }
}

package struct WorkspaceContextProjectionMaterializationRequest: Equatable {
    package struct OccurrenceID: Hashable, Comparable {
        package let rawValue: Int

        package init(rawValue: Int) {
            self.rawValue = rawValue
        }

        package static func < (lhs: OccurrenceID, rhs: OccurrenceID) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    package struct Codemap: Equatable {
        package let content: String
        package let tokens: Int

        package init(content: String, tokens: Int) {
            self.content = content
            self.tokens = tokens
        }
    }

    package struct Occurrence: Equatable {
        package let id: OccurrenceID
        package let file: WorkspaceFileRecord
        package let metadata: WorkspaceSelectionProjection.PathMetadata
        package let mode: WorkspaceSelectionProjection.BaseMode
        package let ranges: [LineRange]
        package let codemap: Codemap?

        package init(
            id: OccurrenceID,
            file: WorkspaceFileRecord,
            metadata: WorkspaceSelectionProjection.PathMetadata,
            mode: WorkspaceSelectionProjection.BaseMode,
            ranges: [LineRange],
            codemap: Codemap?
        ) {
            self.id = id
            self.file = file
            self.metadata = metadata
            self.mode = mode
            self.ranges = ranges
            self.codemap = codemap
        }
    }

    package let provenance: WorkspaceFileContextCapture.Provenance
    package let occurrences: [Occurrence]
    package let requiresContent: Bool
    package let requiresTokenFacts: Bool

    package init(
        provenance: WorkspaceFileContextCapture.Provenance,
        occurrences: [Occurrence],
        requiresContent: Bool,
        requiresTokenFacts: Bool
    ) {
        self.provenance = provenance
        self.occurrences = occurrences
        self.requiresContent = requiresContent
        self.requiresTokenFacts = requiresTokenFacts
    }
}

package struct WorkspaceContextProjectionMaterialization: Equatable {
    package struct TokenFacts: Equatable {
        package let displayTokens: Int
        package let fullTokens: Int

        package init(displayTokens: Int, fullTokens: Int) {
            self.displayTokens = displayTokens
            self.fullTokens = fullTokens
        }
    }

    package struct Occurrence: Equatable {
        package let id: WorkspaceContextProjectionMaterializationRequest.OccurrenceID
        package let content: String?
        package let tokenFacts: TokenFacts?

        package init(
            id: WorkspaceContextProjectionMaterializationRequest.OccurrenceID,
            content: String?,
            tokenFacts: TokenFacts?
        ) {
            self.id = id
            self.content = content
            self.tokenFacts = tokenFacts
        }
    }

    package let provenance: WorkspaceFileContextCapture.Provenance
    package let occurrences: [Occurrence]

    package init(
        provenance: WorkspaceFileContextCapture.Provenance,
        occurrences: [Occurrence]
    ) {
        self.provenance = provenance
        self.occurrences = occurrences
    }
}
