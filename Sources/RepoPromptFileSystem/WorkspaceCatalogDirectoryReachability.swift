import Foundation

package enum WorkspaceCatalogDirectoryReachability {
    package static func shouldTraverse(
        repositoryRelativeDirectory: String,
        rules: IgnoreRulesSnapshot
    ) -> Bool {
        !rules.isIgnored(relativePath: repositoryRelativeDirectory, isDirectory: true)
            || rules.requiresTraversal(for: repositoryRelativeDirectory)
    }
}
