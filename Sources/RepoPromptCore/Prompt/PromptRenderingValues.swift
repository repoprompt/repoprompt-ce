import Foundation

package struct PromptRenderingFileValue: Equatable {
    package let displayPath: String
    package let fileName: String
    package let content: String?
    package let ranges: [LineRange]?
    package let codemapText: String?

    package init(
        displayPath: String,
        fileName: String,
        content: String?,
        ranges: [LineRange]? = nil,
        codemapText: String? = nil
    ) {
        self.displayPath = displayPath
        self.fileName = fileName
        self.content = content
        self.ranges = ranges
        self.codemapText = codemapText
    }
}

package struct PromptRenderingDiffValue: Equatable {
    package let content: String?
    package let ranges: [LineRange]?

    package init(content: String?, ranges: [LineRange]? = nil) {
        self.content = content
        self.ranges = ranges
    }
}

package enum PromptRenderedFileBlockKind: Equatable {
    case codemap
    case content
}

package struct PromptRenderedFileBlock: Equatable {
    package let inputIndex: Int
    package let text: String
    package let kind: PromptRenderedFileBlockKind

    package init(inputIndex: Int, text: String, kind: PromptRenderedFileBlockKind) {
        self.inputIndex = inputIndex
        self.text = text
        self.kind = kind
    }
}

package struct PromptPartitionedFileBlocks: Equatable {
    package let codemapBlocks: [String]
    package let contentBlocks: [String]

    package init(codemapBlocks: [String], contentBlocks: [String]) {
        self.codemapBlocks = codemapBlocks
        self.contentBlocks = contentBlocks
    }
}

package struct PromptRenderedFactualSnippets: Equatable {
    package let fileMap: String?
    package let fileContents: String?
    package let gitDiff: String?

    package init(fileMap: String?, fileContents: String?, gitDiff: String?) {
        self.fileMap = fileMap
        self.fileContents = fileContents
        self.gitDiff = gitDiff
    }
}

package struct PromptFactualEnvelopePolicy: Equatable {
    package enum FileMapEnvelope: Equatable {
        case canonicalFileMap
        case chatStyleFileTree
    }

    package enum WrapperCloseSpacing: Equatable {
        case direct
        case blankLine
    }

    package enum FragmentTerminator: Equatable {
        case lineFeed
        case none
    }

    package let fileMapEnvelope: FileMapEnvelope
    package let fileMapCloseSpacing: WrapperCloseSpacing
    package let fileContentsCloseSpacing: WrapperCloseSpacing
    package let gitDiffCloseSpacing: WrapperCloseSpacing
    package let fragmentTerminator: FragmentTerminator

    package init(
        fileMapEnvelope: FileMapEnvelope,
        fileMapCloseSpacing: WrapperCloseSpacing,
        fileContentsCloseSpacing: WrapperCloseSpacing,
        gitDiffCloseSpacing: WrapperCloseSpacing,
        fragmentTerminator: FragmentTerminator
    ) {
        self.fileMapEnvelope = fileMapEnvelope
        self.fileMapCloseSpacing = fileMapCloseSpacing
        self.fileContentsCloseSpacing = fileContentsCloseSpacing
        self.gitDiffCloseSpacing = gitDiffCloseSpacing
        self.fragmentTerminator = fragmentTerminator
    }

    package static let canonical = PromptFactualEnvelopePolicy(
        fileMapEnvelope: .canonicalFileMap,
        fileMapCloseSpacing: .direct,
        fileContentsCloseSpacing: .direct,
        gitDiffCloseSpacing: .direct,
        fragmentTerminator: .lineFeed
    )

    package static let chatStyleTree = PromptFactualEnvelopePolicy(
        fileMapEnvelope: .chatStyleFileTree,
        fileMapCloseSpacing: .direct,
        fileContentsCloseSpacing: .blankLine,
        gitDiffCloseSpacing: .direct,
        fragmentTerminator: .none
    )

    package var fileMapTag: String {
        switch fileMapEnvelope {
        case .canonicalFileMap:
            "file_map"
        case .chatStyleFileTree:
            "file_tree"
        }
    }

    package var fileContentsTag: String {
        "file_contents"
    }

    package var gitDiffTag: String {
        "git_diff"
    }
}
