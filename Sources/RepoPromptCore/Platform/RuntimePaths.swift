import Foundation

package struct RuntimePaths: Equatable {
    package let stateRoot: URL
    package let cacheRoot: URL
    package let codeMapCacheRoot: URL
    package let agentSupportRoot: URL

    package init(stateRoot: URL, cacheRoot: URL, codeMapCacheRoot: URL, agentSupportRoot: URL) {
        self.stateRoot = stateRoot.standardizedFileURL
        self.cacheRoot = cacheRoot.standardizedFileURL
        self.codeMapCacheRoot = codeMapCacheRoot.standardizedFileURL
        self.agentSupportRoot = agentSupportRoot.standardizedFileURL
    }
}
