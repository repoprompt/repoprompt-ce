import Foundation

package struct CodeStructureProjection: Equatable {
    package struct Omissions: Equatable {
        package let resultLimit: Int
        package let tokenBudget: Int

        package var total: Int {
            resultLimit + tokenBudget
        }

        package init(resultLimit: Int, tokenBudget: Int) {
            self.resultLimit = resultLimit
            self.tokenBudget = tokenBudget
        }
    }

    package struct BudgetCandidate: Equatable {
        package let key: String
        package let estimatedTokens: Int

        package init(key: String, estimatedTokens: Int) {
            self.key = key
            self.estimatedTokens = estimatedTokens
        }
    }

    package struct BudgetSelection: Equatable {
        package let includedKeys: [String]
        package let omissions: Omissions

        package init(includedKeys: [String], omissions: Omissions) {
            self.includedKeys = includedKeys
            self.omissions = omissions
        }
    }

    package let content: String
    package let renderedPaths: [String]
    package let unmappedPaths: [String]
    package let omissions: Omissions

    package var fileCount: Int {
        renderedPaths.count
    }

    package var tokenBudgetHit: Bool {
        omissions.tokenBudget > 0
    }

    package init(
        content: String,
        renderedPaths: [String],
        unmappedPaths: [String],
        omissions: Omissions
    ) {
        self.content = content
        self.renderedPaths = renderedPaths
        self.unmappedPaths = unmappedPaths
        self.omissions = omissions
    }
}

package struct CodeStructureProjectionRequest {
    package struct Entry {
        package let physicalPath: String
        package let displayPath: String
        package let fileAPI: FileAPI?

        package init(physicalPath: String, displayPath: String, fileAPI: FileAPI?) {
            self.physicalPath = physicalPath
            self.displayPath = displayPath
            self.fileAPI = fileAPI
        }
    }

    package struct Budget: Equatable {
        package let resultLimit: Int
        package let tokenBudget: Int
        package let separatorTokenCost: Int

        package init(
            resultLimit: Int,
            tokenBudget: Int = CodeStructureProjectionService.defaultTokenBudget,
            separatorTokenCost: Int = CodeStructureProjectionService.defaultSeparatorTokenCost
        ) {
            self.resultLimit = resultLimit
            self.tokenBudget = tokenBudget
            self.separatorTokenCost = separatorTokenCost
        }
    }

    package let entries: [Entry]
    package let budget: Budget
    package let includeUnmappedPaths: Bool

    package init(
        entries: [Entry],
        budget: Budget,
        includeUnmappedPaths: Bool
    ) {
        self.entries = entries
        self.budget = budget
        self.includeUnmappedPaths = includeUnmappedPaths
    }
}

package struct LocalDefinitionProjection: Equatable {
    package let text: String
    package let fileCount: Int

    package init(text: String, fileCount: Int) {
        self.text = text
        self.fileCount = fileCount
    }

    package static let empty = LocalDefinitionProjection(text: "", fileCount: 0)
}

package struct LocalDefinitionProjectionRequest {
    package enum PathDisplay: Equatable {
        case full
        case relative
    }

    package struct Root: Equatable {
        package let standardizedPath: String
        package let displayName: String

        package init(standardizedPath: String, displayName: String) {
            self.standardizedPath = standardizedPath
            self.displayName = displayName
        }
    }

    package let codeMapUsage: CodeMapUsage
    package let selectedFiles: [WorkspaceFileRecord]
    package let availableFileAPIs: [FileAPI]
    package let pathDisplay: PathDisplay
    package let roots: [Root]

    package init(
        codeMapUsage: CodeMapUsage,
        selectedFiles: [WorkspaceFileRecord],
        availableFileAPIs: [FileAPI],
        pathDisplay: PathDisplay,
        roots: [Root]
    ) {
        self.codeMapUsage = codeMapUsage
        self.selectedFiles = selectedFiles
        self.availableFileAPIs = availableFileAPIs
        self.pathDisplay = pathDisplay
        self.roots = roots
    }
}
