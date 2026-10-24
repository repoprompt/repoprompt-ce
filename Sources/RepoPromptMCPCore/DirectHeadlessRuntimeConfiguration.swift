import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared

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
        customWorkspaceStoragePath: String? = MCPFilesystemIdentity.current.buildFlavor == .debug
            ? UserDefaults(suiteName: AppProfileLocations.current.preferencesDomain)?.string(forKey: "GlobalCustomStorageURL")
            : UserDefaults.standard.string(forKey: "GlobalCustomStorageURL"),
        identity: MCPFilesystemIdentity = .current
    ) throws -> DirectHeadlessRuntimeLocations {
        let profile = sanitizedProfileIdentifier(environment["REPOPROMPT_MCP_HEADLESS_PROFILE"] ?? "default")
        let explicitProfilePath = environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usesExplicitProfileDirectory = explicitProfilePath?.isEmpty == false
        if profile != "default", !usesExplicitProfileDirectory {
            throw DirectHeadlessRuntimeLocationError.profileDirectoryRequired(profile)
        }

        let locations = AppProfileLocations(identity: identity, homeDirectory: homeDirectory, profileName: profile)
        let storageDirectory: URL
        let workspaceStorageDirectory: URL
        let eventDirectory: URL
        let runtimeTemporaryDirectory: URL
        if let explicitProfilePath, !explicitProfilePath.isEmpty {
            let root = URL(fileURLWithPath: explicitProfilePath, isDirectory: true).standardizedFileURL
            let profileRoot = try locations.customWorkspaceRoot(selectedDirectory: root)
            let resolvedRoot = profileRoot.resolvingSymlinksInPath()
            storageDirectory = resolvedRoot
            workspaceStorageDirectory = resolvedRoot.appendingPathComponent("Workspaces", isDirectory: true)
            eventDirectory = resolvedRoot.appendingPathComponent("Events", isDirectory: true)
            runtimeTemporaryDirectory = resolvedRoot.appendingPathComponent("Temporary", isDirectory: true)
        } else {
            let root = locations.applicationSupportRoot
            try locations.validateWritableRoot(root)
            storageDirectory = root
            if let path = customWorkspaceStoragePath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let selectedRoot = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
                workspaceStorageDirectory = try locations.customWorkspaceRoot(selectedDirectory: selectedRoot).standardizedFileURL.resolvingSymlinksInPath()
            } else {
                workspaceStorageDirectory = locations.workspaceRoot
            }
            eventDirectory = root.appendingPathComponent("Events", isDirectory: true)
            runtimeTemporaryDirectory = temporaryDirectory.appendingPathComponent(identity.applicationSupportDirectoryName, isDirectory: true)
        }

        let workingDirectories = try resolvedWorkingDirectories(
            environment["REPOPROMPT_MCP_WORKING_DIRS"]
        )
        return DirectHeadlessRuntimeLocations(
            profileIdentifier: locations.profileIdentifier,
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
