import Foundation
import RepoPromptFoundation

package class FileSystemOperation: Operation, @unchecked Sendable {
    package let fileSystemService: FileSystemService

    package init(fileSystemService: FileSystemService) {
        self.fileSystemService = fileSystemService
        super.init()
    }

    package func createFile(atRelativePath relativePath: String, content: String) async throws {
        try await fileSystemService.createFile(atRelativePath: relativePath, content: content)
    }

    package func editFile(atRelativePath relativePath: String, newContent: String) async throws {
        try await fileSystemService.editFile(atRelativePath: relativePath, newContent: newContent)
    }

    package func deleteFile(atRelativePath relativePath: String) async throws {
        try await fileSystemService.deleteFile(atRelativePath: relativePath)
    }
}
