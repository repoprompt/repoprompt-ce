#if DEBUG
    import Foundation

    /// Captures project Python sources and dependency declarations so an imported helper
    /// cannot change the evaluator while a saved GEPA search is being resumed.
    /// Installed packages and external services remain owned by the selected environment.
    enum PromptLabProgramDependencies {
        private static let excludedDirectories: Set<String> = [
            ".git", ".venv", "venv", "env", "node_modules", "__pycache__", ".build", ".tox", ".mypy_cache", ".pytest_cache"
        ]
        private static let declarations: Set<String> = [
            "pyproject.toml", "uv.lock", "poetry.lock", "Pipfile", "Pipfile.lock", "environment.yml", "environment.yaml"
        ]

        static func snapshot(root: URL) throws -> [String: String] {
            var enumerationError: Error?
            // The enumerator reports each entry relative to `root`. Slicing the absolute path by the
            // root's length is not reliable: the enumerator may canonicalize the root (for example
            // /var/... to /private/var/...) while the caller's root keeps its alias.
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.producesRelativePathURLs],
                errorHandler: { _, error in enumerationError = error
                    return false
                }
            ) else { throw PromptExperimentAuthorityError.invalidRequest("The evaluator project folder cannot be read.") }
            var result: [String: String] = [:]
            var totalBytes = 0
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isDirectory == true || values.isSymbolicLink == true {
                    if values.isSymbolicLink == true || excludedDirectories.contains(file.lastPathComponent) { files.skipDescendants() }
                    continue
                }
                let name = file.lastPathComponent
                guard values.isRegularFile == true,
                      file.pathExtension == "py" || declarations.contains(name) || (name.hasPrefix("requirements") && file.pathExtension == "txt")
                else { continue }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                totalBytes += data.count
                guard result.count < 10000, totalBytes <= 50_000_000 else {
                    throw PromptExperimentAuthorityError.invalidRequest("Choose the evaluator's project folder with at most 10,000 Python/dependency files and 50 MB of source.")
                }
                result[file.relativePath] = PromptExperimentDigest.sha256(data)
            }
            if let enumerationError { throw enumerationError }
            return result
        }
    }
#endif
