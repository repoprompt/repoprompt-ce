import Foundation

enum HeadlessRootAccessPolicy {
    nonisolated static func makeAllowedRoot(path: String, name: String?, fileManager: FileManager = .default) throws -> HeadlessAllowedRoot {
        guard path.hasPrefix("/") else {
            throw HeadlessCommandError("Allowed roots must be absolute paths. Received: \(path)", exitCode: 2)
        }

        let displayURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let resolvedURL = try resolvedExistingDirectoryURL(for: displayURL, fileManager: fileManager)
        guard resolvedURL.path != "/" else {
            throw HeadlessCommandError("Refusing to add '/' as a headless allowed root.", exitCode: 2)
        }

        let rootName = try normalizedName(name) ?? fallbackName(for: displayURL)
        return HeadlessAllowedRoot(
            id: UUID(),
            name: rootName,
            path: displayURL.path,
            resolvedPath: resolvedURL.path,
            addedAt: Date()
        )
    }

    nonisolated static func validationFailures(for roots: [HeadlessAllowedRoot], fileManager: FileManager = .default) -> [String] {
        roots.compactMap { root in
            guard root.path.hasPrefix("/") else {
                return "Root '\(root.name)' is invalid: Allowed roots must be absolute paths. Received: \(root.path)"
            }

            let url = URL(fileURLWithPath: root.path, isDirectory: true)
            do {
                let resolvedURL = try resolvedExistingDirectoryURL(for: url, fileManager: fileManager)
                guard resolvedURL.path != "/" else {
                    return "Root '\(root.name)' is invalid: Refusing to use '/' as a headless allowed root."
                }
                if resolvedURL.path != root.resolvedPath {
                    return "Root '\(root.name)' resolved path changed from \(root.resolvedPath) to \(resolvedURL.path). Remove and re-add it to accept the new target."
                }
                return nil
            } catch {
                return "Root '\(root.name)' is invalid: \(error.localizedDescription)"
            }
        }
    }

    nonisolated static func rootMatches(_ root: HeadlessAllowedRoot, token: String, fileManager: FileManager = .default) -> Bool {
        if root.id.uuidString.caseInsensitiveCompare(token) == .orderedSame || root.name == token || root.path == token || root.resolvedPath == token {
            return true
        }
        guard token.hasPrefix("/") else {
            return false
        }
        let tokenURL = URL(fileURLWithPath: token, isDirectory: true).standardizedFileURL
        let resolvedToken = resolvedPath(for: tokenURL)
        return root.path == tokenURL.path || root.resolvedPath == resolvedToken
    }

    nonisolated static func resolvedExistingDirectoryURL(for url: URL, fileManager: FileManager) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HeadlessCommandError("Directory does not exist: \(url.path)", exitCode: 2)
        }
        guard isDirectory.boolValue else {
            throw HeadlessCommandError("Allowed root is not a directory: \(url.path)", exitCode: 2)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    nonisolated static func resolvedPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated static func path(_ candidate: String, isContainedInOrEqualTo root: String) -> Bool {
        let candidateComponents = URL(fileURLWithPath: candidate).standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return zip(candidateComponents, rootComponents).allSatisfy(==)
    }

    private nonisolated static func normalizedName(_ name: String?) throws -> String? {
        guard let name else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard trimmed != ".", trimmed != ".." else {
            throw HeadlessCommandError("Allowed root name must not be '.' or '..'.", exitCode: 2)
        }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else {
            throw HeadlessCommandError("Allowed root name must not contain path separators: \(trimmed)", exitCode: 2)
        }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
            throw HeadlessCommandError("Allowed root name must not contain control characters.", exitCode: 2)
        }
        return trimmed
    }

    private nonisolated static func fallbackName(for url: URL) -> String {
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return lastPathComponent.isEmpty ? url.path : lastPathComponent
    }
}
