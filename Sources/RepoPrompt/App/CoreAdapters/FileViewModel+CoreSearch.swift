import Foundation
import RepoPromptCore

private extension FileViewModel {
    var coreSearchDescriptor: SearchFileDescriptor {
        SearchFileDescriptor(
            id: id,
            name: name,
            relativePath: relativePath,
            standardizedRelativePath: standardizedRelativePath,
            fullPath: fullPath,
            standardizedFullPath: standardizedFullPath,
            standardizedRootFolderPath: standardizedRootFolderPath,
            fileExtension: fileExtension,
            contentSnapshot: { [self] policy in
                await searchContentSnapshot(freshnessPolicy: policy)
            }
        )
    }
}

extension FileSearchActor {
    func search(pattern: String, isRegex: Bool = false, wasAutoCorrected: inout Bool?, options: SearchOptions = SearchOptions(), in files: [FileViewModel]) async throws -> [SearchMatch] {
        try await search(pattern: pattern, isRegex: isRegex, wasAutoCorrected: &wasAutoCorrected, options: options, in: files.map(\.coreSearchDescriptor))
    }

    func search(pattern: String, isRegex: Bool = false, options: SearchOptions = SearchOptions(), in files: [FileViewModel]) async throws -> [SearchMatch] {
        var corrected: Bool? = nil
        return try await search(pattern: pattern, isRegex: isRegex, wasAutoCorrected: &corrected, options: options, in: files)
    }

    func searchPaths(pattern: String, limit: Int = 100, in files: [FileViewModel], caseInsensitive: Bool = true, isRegex: Bool = false, aliasByRootPath: [String: String]? = nil) async throws -> [String] {
        try await searchPaths(pattern: pattern, limit: limit, in: files.map(\.coreSearchDescriptor), caseInsensitive: caseInsensitive, isRegex: isRegex, aliasByRootPath: aliasByRootPath)
    }

    func searchUnified(pattern: String, isRegex: Bool = false, wasAutoCorrected: inout Bool?, options: SearchOptions = SearchOptions(), in files: [FileViewModel], aliasByRootPath: [String: String]? = nil) async throws -> SearchResults {
        try await searchUnified(pattern: pattern, isRegex: isRegex, wasAutoCorrected: &wasAutoCorrected, options: options, in: files.map(\.coreSearchDescriptor), aliasByRootPath: aliasByRootPath)
    }

    func searchUnified(pattern: String, isRegex: Bool = false, options: SearchOptions = SearchOptions(), in files: [FileViewModel], aliasByRootPath: [String: String]? = nil) async throws -> SearchResults {
        var corrected: Bool? = nil
        return try await searchUnified(pattern: pattern, isRegex: isRegex, wasAutoCorrected: &corrected, options: options, in: files, aliasByRootPath: aliasByRootPath)
    }
}
