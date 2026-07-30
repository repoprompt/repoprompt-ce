@testable import RepoPromptApp
import XCTest

struct FileSystemTemporaryRoots {
    private var roots: [URL] = []

    mutating func makeRoot(suiteName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(suiteName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    mutating func removeAll() {
        for url in roots {
            try? FileManager.default.removeItem(at: url)
        }
        roots.removeAll()
    }
}

enum FileSystemTestSupport {
    static func write(_ content: String, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func createDirectorySymlinkOrSkip(at link: URL, destination: URL) throws {
        do {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination.path)
        } catch {
            throw XCTSkip("Directory symlink creation unavailable in this environment: \(error)")
        }
    }

    static func collectRelativePaths(from service: FileSystemService, root: URL) async throws -> Set<String> {
        var paths = Set<String>()
        for try await event in await service.loadContentsInChunks(of: root, chunkSize: 2) {
            switch event {
            case let .preparedItems(chunk):
                paths.formUnion(chunk.folders.map(\.relativePath))
                paths.formUnion(chunk.files.map(\.relativePath))
            case let .items(legacyItems):
                paths.formUnion(legacyItems.map { item, _ in item.relativePath(rootPath: root.path) })
            case .totalFileCount:
                continue
            }
        }
        return paths
    }
}
