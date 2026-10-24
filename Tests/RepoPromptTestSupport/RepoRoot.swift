import Foundation

/// Locates the repository root from a test source file. Shared by every test target via
/// `RepoPromptTestSupport`; never a production dependency.
package enum RepoRoot {
    package static func url(
        filePath: StaticString = #filePath,
        fileManager: FileManager = .default
    ) throws -> URL {
        var current = URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .standardizedFileURL

        while true {
            let packageManifest = current.appendingPathComponent("Package.swift")
            let sourcesRoot = current.appendingPathComponent("Sources/RepoPrompt", isDirectory: true)
            var packageIsDirectory: ObjCBool = false
            var sourcesIsDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: packageManifest.path, isDirectory: &packageIsDirectory),
               !packageIsDirectory.boolValue,
               fileManager.fileExists(atPath: sourcesRoot.path, isDirectory: &sourcesIsDirectory),
               sourcesIsDirectory.boolValue
            {
                return current
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                throw RepoRootError.notFound(startingAt: "\(filePath)")
            }
            current = parent
        }
    }

    package static func relativePath(for fileURL: URL, relativeTo rootURL: URL) -> String {
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard filePath.hasPrefix(prefix) else { return filePath }
        return String(filePath.dropFirst(prefix.count))
    }
}

package enum RepoRootError: Error, CustomStringConvertible {
    case notFound(startingAt: String)

    package var description: String {
        switch self {
        case let .notFound(startingAt):
            "Could not find repository root containing Package.swift and Sources/RepoPrompt when walking upward from \(startingAt)"
        }
    }
}
