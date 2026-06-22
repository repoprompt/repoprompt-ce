import Foundation

struct HeadlessPathResolver {
    let roots: [HeadlessAllowedRoot]
    let fileManager: FileManager
    let secureFileAccess: HeadlessSecureFileAccess

    init(
        roots: [HeadlessAllowedRoot],
        fileManager: FileManager = .default,
        secureFileAccess: HeadlessSecureFileAccess = HeadlessSecureFileAccess()
    ) {
        self.roots = roots
        self.fileManager = fileManager
        self.secureFileAccess = secureFileAccess
    }

    func resolve(_ input: String, requireExists: Bool = true) throws -> HeadlessResolvedPath {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HeadlessCommandError("Path must not be empty.", exitCode: 2)
        }
        guard !roots.isEmpty else {
            throw HeadlessCommandError("No roots are bound to the active headless workspace.", exitCode: 2)
        }

        if trimmed.hasPrefix("/") {
            return try resolvedAbsolute(URL(fileURLWithPath: trimmed), requireExists: requireExists)
        }

        if let prefixed = try resolveRootPrefixed(trimmed, requireExists: requireExists) {
            return prefixed
        }

        var matches: [HeadlessResolvedPath] = []
        for root in roots {
            let candidate = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent(trimmed, isDirectory: false)
            do {
                let resolved = try resolvedCandidate(candidate, root: root, requireExists: requireExists)
                matches.append(resolved)
            } catch let error as HeadlessCommandError {
                if requireExists, error.exitCode == 2 {
                    continue
                }
                throw error
            }
        }

        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw HeadlessCommandError("Path is not available under the active workspace roots: \(trimmed)", exitCode: 2)
        default:
            let roots = matches.map(\.root.name).joined(separator: ", ")
            throw HeadlessCommandError("Ambiguous relative path '\(trimmed)' matches multiple roots: \(roots). Prefix with RootName/ to disambiguate.", exitCode: 2)
        }
    }

    func resolveMany(_ inputs: [String], requireExists: Bool = true) throws -> [HeadlessResolvedPath] {
        try inputs.map { try resolve($0, requireExists: requireExists) }
    }

    private func resolveRootPrefixed(_ input: String, requireExists: Bool) throws -> HeadlessResolvedPath? {
        let parts = input.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first else {
            return nil
        }
        let token = String(first)
        guard let root = roots.first(where: { root in
            root.name == token || root.id.uuidString.caseInsensitiveCompare(token) == .orderedSame
        }) else {
            return nil
        }
        let rest = parts.dropFirst().map(String.init).joined(separator: "/")
        let base = URL(fileURLWithPath: root.path, isDirectory: true)
        let candidate = rest.isEmpty ? base : base.appendingPathComponent(rest, isDirectory: false)
        return try resolvedCandidate(candidate, root: root, lexicalRootPath: root.path, requireExists: requireExists)
    }

    private func resolvedAbsolute(_ url: URL, requireExists: Bool) throws -> HeadlessResolvedPath {
        let standardized = url.standardizedFileURL
        let containingRoots = roots.compactMap { root -> (root: HeadlessAllowedRoot, lexicalRootPath: String)? in
            if HeadlessRootAccessPolicy.path(standardized.path, isContainedInOrEqualTo: root.path) {
                return (root, root.path)
            }
            if HeadlessRootAccessPolicy.path(standardized.path, isContainedInOrEqualTo: root.resolvedPath) {
                return (root, root.resolvedPath)
            }
            return nil
        }
        guard let match = containingRoots.sorted(by: { $0.lexicalRootPath.count > $1.lexicalRootPath.count }).first else {
            throw HeadlessCommandError("Path is outside the active headless allowed roots: \(url.path)", exitCode: 2)
        }
        return try resolvedCandidate(standardized, root: match.root, lexicalRootPath: match.lexicalRootPath, requireExists: requireExists)
    }

    private func resolvedCandidate(
        _ candidate: URL,
        root: HeadlessAllowedRoot,
        lexicalRootPath: String? = nil,
        requireExists: Bool
    ) throws -> HeadlessResolvedPath {
        let standardized = candidate.standardizedFileURL
        let lexicalRootPath = lexicalRootPath ?? root.path
        guard HeadlessRootAccessPolicy.path(standardized.path, isContainedInOrEqualTo: lexicalRootPath) else {
            throw HeadlessCommandError("Path is outside allowed root '\(root.name)': \(candidate.path)", exitCode: 2)
        }
        let resolvedURL = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard HeadlessRootAccessPolicy.path(resolvedURL.path, isContainedInOrEqualTo: root.resolvedPath) else {
            throw HeadlessCommandError("Path resolves outside allowed root '\(root.name)': \(candidate.path)", exitCode: 2)
        }
        let relativePath = Self.relativePath(forResolvedPath: standardized.path, rootResolvedPath: lexicalRootPath)
        let metadata: HeadlessSecureFileMetadata? = if requireExists {
            try secureFileAccess.inspect(root: root, relativePath: relativePath)
        } else {
            nil
        }
        let descriptorResolvedURL = relativePath.isEmpty
            ? URL(fileURLWithPath: root.resolvedPath, isDirectory: true)
            : URL(fileURLWithPath: root.resolvedPath, isDirectory: true).appendingPathComponent(relativePath)
        let displayPath = relativePath.isEmpty ? root.name : "\(root.name)/\(relativePath)"
        return HeadlessResolvedPath(
            root: root,
            url: standardized,
            resolvedURL: descriptorResolvedURL.standardizedFileURL,
            relativePath: relativePath,
            displayPath: displayPath,
            isDirectory: metadata?.kind == .directory,
            isRegularFile: metadata?.kind == .regularFile
        )
    }

    static func relativePath(forResolvedPath path: String, rootResolvedPath: String) -> String {
        let root = URL(fileURLWithPath: rootResolvedPath).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate != root else {
            return ""
        }
        let prefix = root.hasSuffix("/") ? root : "\(root)/"
        guard candidate.hasPrefix(prefix) else {
            return candidate
        }
        return String(candidate.dropFirst(prefix.count))
    }
}
