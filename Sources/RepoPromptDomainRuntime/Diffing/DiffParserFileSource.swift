import Foundation

/// Read-only live file access for XML diff parsing. Resolution policy and file
/// authority remain with the workspace host; the parser never writes files.
package protocol DiffParserFileSource {
    func pathLocation(_ path: String, exactMatchOnly: Bool) async -> DiffParserFileLocation?

    /// Read using the identity returned by resolution, without resolving again
    /// against an active selection. Nil means no file was found; an existing
    /// file whose latest content is unavailable returns a value with nil content.
    func readFile(at location: DiffParserFileLocation) async -> DiffParserFileContent?
}

package struct DiffParserFileLocation: Hashable {
    package let rootPath: String
    package let correctedPath: String
    package let rootIdentifier: UUID?

    package init(rootPath: String, correctedPath: String, rootIdentifier: UUID?) {
        self.rootPath = rootPath
        self.correctedPath = correctedPath
        self.rootIdentifier = rootIdentifier
    }
}

package struct DiffParserFileContent {
    package let content: String?

    package init(content: String?) {
        self.content = content
    }
}
