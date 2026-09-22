import Foundation
import RepoPromptDomainRuntime

struct DirectHeadlessRuntimeLocations: Equatable {
    let profileIdentifier: String
    let storageDirectory: URL
    let workspaceStorageDirectory: URL
    let eventDirectory: URL
    let temporaryDirectory: URL
    let workingDirectories: [URL]
    let usesExplicitProfileDirectory: Bool

    var mayBootstrapIsolatedWorkspace: Bool {
        usesExplicitProfileDirectory && !workingDirectories.isEmpty
    }
}

enum DirectHeadlessRuntimeLocationError: Error, Equatable {
    case profileDirectoryRequired(String)
}

enum DirectHeadlessRuntimeLocationResolver {
    static func resolve(
        environment: [String: String],
        currentDirectory _: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        customWorkspaceStoragePath: String? = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
    ) throws -> DirectHeadlessRuntimeLocations {
        let profile = sanitizedProfileIdentifier(
            environment["REPOPROMPT_MCP_HEADLESS_PROFILE"] ?? "default"
        )
        let explicitProfilePath = environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usesExplicitProfileDirectory = explicitProfilePath?.isEmpty == false
        if profile != "default", !usesExplicitProfileDirectory {
            throw DirectHeadlessRuntimeLocationError.profileDirectoryRequired(profile)
        }

        let storageDirectory: URL
        let workspaceStorageDirectory: URL
        let eventDirectory: URL
        let runtimeTemporaryDirectory: URL
        if let explicitProfilePath, !explicitProfilePath.isEmpty {
            let root = URL(fileURLWithPath: explicitProfilePath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            storageDirectory = root
            workspaceStorageDirectory = root.appendingPathComponent("Workspaces", isDirectory: true)
            eventDirectory = root.appendingPathComponent("Events", isDirectory: true)
            runtimeTemporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)
        } else {
            let root = homeDirectory
                .appendingPathComponent("Library/Application Support/RepoPrompt CE", isDirectory: true)
                .standardizedFileURL
            storageDirectory = root
            workspaceStorageDirectory = customWorkspaceStoragePath.flatMap { path -> URL? in
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: trimmed, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            } ?? root.appendingPathComponent("Workspaces", isDirectory: true)
            eventDirectory = root.appendingPathComponent("Events", isDirectory: true)
            runtimeTemporaryDirectory = temporaryDirectory
                .appendingPathComponent("RepoPrompt CE", isDirectory: true)
        }

        let workingDirectories = try resolvedWorkingDirectories(
            environment["REPOPROMPT_MCP_WORKING_DIRS"]
        )
        return DirectHeadlessRuntimeLocations(
            profileIdentifier: profile,
            storageDirectory: storageDirectory,
            workspaceStorageDirectory: workspaceStorageDirectory,
            eventDirectory: eventDirectory,
            temporaryDirectory: runtimeTemporaryDirectory,
            workingDirectories: workingDirectories,
            usesExplicitProfileDirectory: usesExplicitProfileDirectory
        )
    }

    private static func resolvedWorkingDirectories(_ rawValue: String?) throws -> [URL] {
        guard let rawValue else { return [] }
        let values = rawValue.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return try validatedWorkingDirectories(values)
    }

    static func validatedWorkingDirectories(_ values: [String]) throws -> [URL] {
        guard !values.isEmpty else {
            throw DomainStandaloneScopeError.invalidWorkingDirectory("")
        }
        var seen: Set<String> = []
        return try values.map { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(value)
            }
            let url = URL(fileURLWithPath: trimmed, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(url.path).inserted
            else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(value)
            }
            return url
        }
    }

    private static func sanitizedProfileIdentifier(_ value: String) -> String {
        let allowed = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar))
                : "_"
        }
        let result = String(allowed).prefix(80)
        return result.isEmpty ? "default" : String(result)
    }
}
