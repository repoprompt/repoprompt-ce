import Foundation

enum HeadlessTestRepoRoot {
    static func url(filePath: StaticString = #filePath) throws -> URL {
        var current = URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .standardizedFileURL
        while true {
            let manifest = current.appendingPathComponent("Package.swift")
            let sourceRoot = current.appendingPathComponent("Sources/RepoPromptHeadless", isDirectory: true)
            if FileManager.default.fileExists(atPath: manifest.path),
               FileManager.default.fileExists(atPath: sourceRoot.path)
            {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else {
                throw CocoaError(.fileNoSuchFile)
            }
            current = parent
        }
    }
}
