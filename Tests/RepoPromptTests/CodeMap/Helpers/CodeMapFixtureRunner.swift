import Foundation
@testable import RepoPromptApp

enum CodeMapFixtureRunner {
    static func expectedFileTree() -> String {
        """
        <ROOT>
        ├── nested
        │   └── helper.py +
        ├── sample.swift +
        └── worker.go +


        (+ denotes code-map available)
        """
            + "\n"
    }

    static func renderFixtureFileTree(
        tempRoot: URL,
        mode: String = "full",
        selectedFileIDs: Set<UUID> = []
    ) -> String {
        let rootPath = StandardizedPath.absolute(tempRoot.path)
        let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let helperID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let goID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let rootID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let folderID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        let nestedFolder = FileTreeFolderSnapshot(
            id: folderID,
            name: "nested",
            fullPath: tempRoot.appendingPathComponent("nested").path,
            standardizedFullPath: StandardizedPath.absolute(tempRoot.appendingPathComponent("nested").path),
            standardizedRootPath: rootPath,
            children: [
                .file(FileTreeFileSnapshot(
                    id: helperID,
                    name: "helper.py",
                    fileExtension: "py",
                    hasCodeMap: true
                ))
            ]
        )

        let root = FileTreeFolderSnapshot(
            id: rootID,
            name: "Fixtures",
            fullPath: tempRoot.path,
            standardizedFullPath: rootPath,
            standardizedRootPath: rootPath,
            children: [
                .file(FileTreeFileSnapshot(
                    id: sourceID,
                    name: "sample.swift",
                    fileExtension: "swift",
                    hasCodeMap: true
                )),
                .folder(nestedFolder),
                .file(FileTreeFileSnapshot(
                    id: goID,
                    name: "worker.go",
                    fileExtension: "go",
                    hasCodeMap: true
                ))
            ]
        )

        let snapshot = FileTreeSelectionSnapshot(
            roots: [root],
            selectedFileIDs: selectedFileIDs,
            mode: mode,
            showFullPaths: true,
            onlyIncludeRootsWithSelectedFiles: false,
            includeLegend: true,
            showCodeMapMarkers: true
        )
        let rendered = CodeMapExtractor.generateFileTree(using: snapshot)
        return rendered.isEmpty ? "" : normalize(rendered, tempRoot: tempRoot)
    }

    static func normalize(_ text: String, tempRoot: URL? = nil) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if let tempRoot {
            normalized = normalized.replacingOccurrences(
                of: StandardizedPath.absolute(tempRoot.path),
                with: "<ROOT>"
            )
            normalized = normalized.replacingOccurrences(of: tempRoot.path, with: "<ROOT>")
        }
        while normalized.hasSuffix("\n\n") {
            normalized.removeLast()
        }
        if !normalized.hasSuffix("\n") {
            normalized.append("\n")
        }
        return normalized
    }
}
