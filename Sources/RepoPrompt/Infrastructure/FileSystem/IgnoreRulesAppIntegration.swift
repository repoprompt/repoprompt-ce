import Darwin
import Foundation
import RepoPromptFileSystem
import RepoPromptSettingsCore
import RepoPromptVCS

/// Shared defaults and legacy key handling for app-wide ignore preferences.
///
/// Kept outside `IgnoreRulesManager` so JSON-backed settings, legacy mirrors,
/// and runtime ignore-rule loading agree on the canonical defaults/version.
extension IgnoreSettingsDefaults {
    static func resolvedGlobalIgnoreDefaults(defaults: UserDefaults = .standard) -> String {
        let storedObject = defaults.object(forKey: globalIgnoreDefaultsKey)
        let stored = defaults.string(forKey: globalIgnoreDefaultsKey)
        let storedVersion = defaults.object(forKey: globalIgnoreDefaultsVersionKey) as? Int ?? 0

        guard storedObject != nil, let stored else {
            defaults.set(canonicalGlobalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return canonicalGlobalIgnoreDefaults
        }

        guard storedVersion < currentGlobalIgnoreDefaultsVersion else {
            return stored
        }

        guard !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaults.set(canonicalGlobalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return canonicalGlobalIgnoreDefaults
        }

        let have = normalizedPatterns(stored)
        let required = normalizedPatterns(canonicalGlobalIgnoreDefaults)
        let missing = required.subtracting(have)

        guard !missing.isEmpty else {
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return stored
        }

        let upgraded = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n# (Auto-upgraded to v\(currentGlobalIgnoreDefaultsVersion))\n"
            + missing.sorted().joined(separator: "\n")
            + "\n"
        defaults.set(upgraded, forKey: globalIgnoreDefaultsKey)
        defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
        return upgraded
    }

    private static func normalizedPatterns(_ text: String) -> Set<String> {
        Set(
            text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
    }
}

extension IgnoreRulePolicy {
    static func resolvingLoadedRoot(_ rawRoot: URL) throws -> IgnoreRulePolicy {
        let loadedRoot = rawRoot.resolvingSymlinksInPath().standardizedFileURL
        var loadedStatus = stat()
        guard lstat(loadedRoot.path, &loadedStatus) == 0,
              loadedStatus.st_mode & S_IFMT == S_IFDIR
        else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }

        var candidate = loadedRoot
        while true {
            let dotGit = candidate.appendingPathComponent(".git")
            var dotGitStatus = stat()
            if lstat(dotGit.path, &dotGitStatus) == 0 {
                let kind = dotGitStatus.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG,
                      let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate),
                      validatedContainingGitLayout(layout)
                else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }
                let repositoryRoot = layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL
                guard repositoryRoot == candidate,
                      loadedRoot.path == repositoryRoot.path
                      || loadedRoot.path.hasPrefix(repositoryRoot.path + "/")
                else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }
                let relativePath = loadedRoot.path == repositoryRoot.path
                    ? ""
                    : String(loadedRoot.path.dropFirst(repositoryRoot.path.count + 1))
                let prefix = try GitRepositoryRelativeRootPrefix(relativePath)
                guard prefix.value.split(separator: "/").first != ".git" else {
                    throw IgnoreRulePolicyResolutionError.ambiguousGitTopology
                }
                return .gitRoot(repositoryRelativeRootPrefix: prefix)
            }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard candidate.path != "/" else { break }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return .nonGitRoot
    }

    private static func validatedContainingGitLayout(_ layout: GitRepositoryLayout) -> Bool {
        func isRegularFile(_ url: URL) -> Bool {
            var value = stat()
            return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
        }
        func isDirectory(_ url: URL) -> Bool {
            var value = stat()
            return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
        }
        return isDirectory(layout.gitDir)
            && isDirectory(layout.commonDir)
            && isRegularFile(layout.gitDir.appendingPathComponent("HEAD"))
            && isRegularFile(layout.commonDir.appendingPathComponent("config"))
            && isDirectory(layout.commonDir.appendingPathComponent("objects"))
    }
}

extension GitRepositoryRelativeRootPrefix: IgnoreRepositoryRootPrefix {}

extension IgnoreRulesManager {
    static let shared = FileSystemAppIntegration.makeIgnoreRulesManager()
}

extension WorkspaceRootCatalogPolicyIdentity {
    static let canonicalDefaults = WorkspaceRootCatalogPolicyIdentity(
        schemaVersion: currentSchemaVersion,
        mandatoryIgnorePolicyIdentity: WorkspaceGitignorePolicyIdentity.current.rawValue,
        globalIgnoreDefaultsDigest: IgnoreRulesManager.globalIgnoreDefaultsDigest(
            for: IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
        ),
        respectRepoIgnore: true,
        respectCursorignore: true,
        enableHierarchicalIgnores: true,
        skipSymlinks: true
    )
}

extension WorkspaceRootByteExactPathKey {
    static func rootRelativePath(repositoryRelativePath: String, prefix: GitRepositoryRelativeRootPrefix) -> String? {
        let pathBytes = Array(repositoryRelativePath.utf8)
        let prefixBytes = Array(prefix.value.utf8)
        guard !prefixBytes.isEmpty else { return repositoryRelativePath }
        let requiredPrefix = prefixBytes + [UInt8(ascii: "/")]
        guard pathBytes.starts(with: requiredPrefix), pathBytes.count > requiredPrefix.count else { return nil }
        return String(decoding: pathBytes.dropFirst(requiredPrefix.count), as: UTF8.self)
    }
}
