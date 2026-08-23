import Foundation
import RepoPromptRuntimeModel
import RepoPromptShared

public struct WorkspaceCodeMapBuildResult: Hashable, Sendable {
    public let status: String
    public let language: String?
    public let content: String
    public let contentDigest: String

    public init(status: String, language: String?, content: String, contentDigest: String) {
        self.status = status
        self.language = language
        self.content = content
        self.contentDigest = contentDigest
    }
}

public protocol WorkspaceCodeMapBuilding: Sendable {
    func build(content: String, fileExtension: String) throws -> WorkspaceCodeMapBuildResult
}

public struct UnavailableWorkspaceCodeMapBuilder: WorkspaceCodeMapBuilding {
    public init() {}

    public func build(content _: String, fileExtension _: String) throws -> WorkspaceCodeMapBuildResult {
        throw ServiceAPIError(code: .capabilityMissing, message: "Code-map capability is unavailable")
    }
}

public protocol WorkspaceCommandRunning: Sendable {
    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int) async throws -> String
    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int, environment: [String: String]) async throws -> String
    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int, launchValidation: @escaping @Sendable () throws -> Void) async throws -> String
}

public extension WorkspaceCommandRunning {
    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int, environment _: [String: String]) async throws -> String {
        try await run(executable: executable, arguments: arguments, workingDirectory: workingDirectory, maximumBytes: maximumBytes)
    }

    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int, launchValidation: @escaping @Sendable () throws -> Void) async throws -> String {
        try launchValidation()
        return try await run(executable: executable, arguments: arguments, workingDirectory: workingDirectory, maximumBytes: maximumBytes)
    }
}

public actor LocalWorkspaceCommandRunner: WorkspaceCommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int) async throws -> String {
        try await run(executable: executable, arguments: arguments, workingDirectory: workingDirectory, maximumBytes: maximumBytes, environment: [:], launchValidation: {})
    }

    public func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int, environment: [String: String]) async throws -> String {
        try await run(executable: executable, arguments: arguments, workingDirectory: workingDirectory, maximumBytes: maximumBytes, environment: environment, launchValidation: {})
    }

    public func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int, launchValidation: @escaping @Sendable () throws -> Void) async throws -> String {
        try await run(executable: executable, arguments: arguments, workingDirectory: workingDirectory, maximumBytes: maximumBytes, environment: [:], launchValidation: launchValidation)
    }

    private func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int, environment: [String: String], launchValidation: @escaping @Sendable () throws -> Void) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Required workspace executable is unavailable")
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        }
        process.standardOutput = output
        process.standardError = errors
        try launchValidation()
        try process.run()
        async let outputData = output.fileHandleForReading.readToEnd()
        async let errorData = errors.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        let stdout = try await outputData ?? Data()
        let stderr = try await errorData ?? Data()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.prefix(8192), as: UTF8.self)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Workspace command failed: \(message)")
        }
        return String(decoding: stdout.prefix(maximumBytes), as: UTF8.self)
    }
}

public actor ProjectToolAuthority {
    private let project: ProjectAuthority
    private let filesystem: any FilesystemAuthorityPort
    private let commandRunner: any WorkspaceCommandRunning
    private let codeMapBuilder: any WorkspaceCodeMapBuilding
    private let gitExecutable: String

    public init(
        project: ProjectAuthority,
        filesystem: any FilesystemAuthorityPort,
        commandRunner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        codeMapBuilder: any WorkspaceCodeMapBuilding = UnavailableWorkspaceCodeMapBuilder(),
        gitExecutable: String = "/usr/bin/git"
    ) {
        self.project = project
        self.filesystem = filesystem
        self.commandRunner = commandRunner
        self.codeMapBuilder = codeMapBuilder
        self.gitExecutable = gitExecutable
    }

    public func tree(_ request: ProjectTreeRequest, settings: AdvancedServerSettings = .default) async throws -> [ProjectTreeEntry] {
        let root = try await project.root(rootID: request.rootID)
        let start = request.logicalPath.isEmpty
            ? root.snapshot.canonicalPath
            : try await project.authorize(rootID: request.rootID, logicalPath: request.logicalPath, filesystem: filesystem)
        let maximumDepth = max(0, min(request.maximumDepth, 32))
        let maximumEntries = max(1, min(request.maximumEntries, 20000))
        var entries: [ProjectTreeEntry] = []
        var visited = Set<String>()
        _ = try walkTree(
            rootID: request.rootID,
            rootPath: root.snapshot.canonicalPath,
            currentPath: start,
            depth: 0,
            maximumDepth: maximumDepth,
            maximumEntries: maximumEntries,
            settings: settings,
            visited: &visited,
            entries: &entries
        )
        return entries
    }

    public func search(_ request: ProjectSearchRequest, settings: AdvancedServerSettings = .default) async throws -> [ProjectSearchHit] {
        guard !request.query.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Search query is required") }
        let root = try await project.root(rootID: request.rootID)
        let start = request.logicalPath.isEmpty
            ? root.snapshot.canonicalPath
            : try await project.authorize(rootID: request.rootID, logicalPath: request.logicalPath, filesystem: filesystem)
        let maximumResults = max(1, min(request.maximumResults, 2000))
        let maximumFileBytes = max(1, min(request.maximumFileBytes, 8_388_608))
        let expression = try request.useRegex ? NSRegularExpression(pattern: request.query) : nil
        var hits: [ProjectSearchHit] = []
        var visited = Set<String>()
        try scanFiles(
            request: request,
            rootPath: root.snapshot.canonicalPath,
            currentPath: start,
            maximumResults: maximumResults,
            maximumFileBytes: maximumFileBytes,
            expression: expression,
            settings: settings,
            visited: &visited,
            hits: &hits
        )
        return hits
    }

    private func searchFiles(request: ProjectSearchRequest, start: String, rootPath: String, maximumResults: Int, maximumFileBytes: Int, expression: NSRegularExpression?) throws -> [ProjectSearchHit] {
        var hits: [ProjectSearchHit] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: start), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in enumerator {
            if hits.count >= maximumResults { break }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumFileBytes else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let content = String(data: data, encoding: .utf8) else { continue }
            let relative = Self.relativePath(url.path, root: rootPath)
            for (offset, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                let matched = if let expression {
                    expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                } else {
                    text.localizedCaseInsensitiveContains(request.query)
                }
                if matched {
                    hits.append(ProjectSearchHit(rootID: request.rootID, logicalPath: relative, line: offset + 1, preview: String(text.prefix(1000))))
                    if hits.count >= maximumResults { break }
                }
            }
        }
        return hits
    }

    public func readFile(_ request: ProjectFileRequest) async throws -> ProjectFileSnapshot {
        let path = try await project.authorize(rootID: request.rootID, logicalPath: request.logicalPath, filesystem: filesystem)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ServiceAPIError(code: .notFound, message: "Authorized file was not found")
        }
        let maximumBytes = max(1, min(request.maximumBytes, 8_388_608))
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard let source = String(data: data.prefix(maximumBytes), encoding: .utf8) else {
            throw ServiceAPIError(code: .invalidRequest, message: "File is not UTF-8 text")
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, (request.startLine ?? 1) - 1)
        let end = min(lines.count, start + max(1, min(request.lineCount ?? lines.count, 20000)))
        let content = start < end ? lines[start ..< end].joined(separator: "\n") : ""
        return ProjectFileSnapshot(rootID: request.rootID, logicalPath: request.logicalPath, content: content, contentDigest: PortableContentDigest.sha256Hex(data), truncated: data.count > maximumBytes || end < lines.count)
    }

    public func codeMap(_ request: ProjectCodeMapRequest, settings: AdvancedServerSettings = .default) async throws -> ProjectCodeMapSnapshot {
        guard !settings.codeMapsGloballyDisabled else {
            throw ServiceAPIError(code: .capabilityMissing, message: AdvancedServerSettings.codeMapsGloballyDisabledMCPMessage)
        }
        let path = try await project.authorize(rootID: request.rootID, logicalPath: request.logicalPath, filesystem: filesystem)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ServiceAPIError(code: .notFound, message: "Authorized file was not found")
        }
        let maximumBytes = max(1, min(request.maximumBytes, 5_242_880))
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            return ProjectCodeMapSnapshot(rootID: request.rootID, logicalPath: request.logicalPath, status: "oversize", language: nil, content: "", contentDigest: PortableContentDigest.sha256Hex(data))
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ServiceAPIError(code: .invalidRequest, message: "File is not UTF-8 text")
        }
        let result = try codeMapBuilder.build(content: source, fileExtension: URL(fileURLWithPath: path).pathExtension)
        return ProjectCodeMapSnapshot(rootID: request.rootID, logicalPath: request.logicalPath, status: result.status, language: result.language, content: result.content, contentDigest: result.contentDigest)
    }

    public func diff(_ request: ProjectDiffRequest) async throws -> ProjectDiffSnapshot {
        guard Self.safeRevision(request.comparison) else { throw ServiceAPIError(code: .invalidRequest, message: "Git comparison is invalid") }
        let root = try await project.root(rootID: request.rootID)
        for path in request.logicalPaths {
            _ = try await project.authorize(rootID: request.rootID, logicalPath: path, filesystem: filesystem)
        }
        let maximumBytes = max(1, min(request.maximumBytes, 8_388_608))
        let arguments = ["-C", root.snapshot.canonicalPath, "diff", "--no-ext-diff", "--no-textconv", "--color=never", request.comparison, "--"] + request.logicalPaths
        let patch = try await commandRunner.run(executable: gitExecutable, arguments: arguments, workingDirectory: root.snapshot.canonicalPath, maximumBytes: maximumBytes)
        let data = Data(patch.utf8)
        return ProjectDiffSnapshot(rootID: request.rootID, comparison: request.comparison, patch: patch, truncated: data.count >= maximumBytes, contentDigest: PortableContentDigest.sha256Hex(data))
    }

    @discardableResult
    private func walkTree(
        rootID: UUID,
        rootPath: String,
        currentPath: String,
        depth: Int,
        maximumDepth: Int,
        maximumEntries: Int,
        settings: AdvancedServerSettings,
        visited: inout Set<String>,
        entries: inout [ProjectTreeEntry]
    ) throws -> Bool {
        guard entries.count < maximumEntries, depth <= maximumDepth else { return false }
        let canonical = URL(fileURLWithPath: currentPath).resolvingSymlinksInPath().standardizedFileURL.path
        guard Self.isInside(canonical, root: rootPath), visited.insert(canonical).inserted else { return false }
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: currentPath),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var emitted = false
        for url in urls {
            guard entries.count < maximumEntries else { return emitted }
            let relative = Self.relativePath(url.path, root: rootPath)
            guard !Self.isIgnored(relativePath: relative, rootPath: rootPath, settings: settings) else { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true, !settings.followSymbolicLinks { continue }
            let resolvedURL = values.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
            guard Self.isInside(resolvedURL.path, root: rootPath) else { continue }
            let resolvedValues = try resolvedURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if resolvedValues.isDirectory == true {
                let insertion = entries.count
                if settings.showEmptyFolders {
                    entries.append(ProjectTreeEntry(rootID: rootID, logicalPath: relative, isDirectory: true, size: nil))
                }
                let childEmitted = depth < maximumDepth
                    ? try walkTree(rootID: rootID, rootPath: rootPath, currentPath: resolvedURL.path, depth: depth + 1, maximumDepth: maximumDepth, maximumEntries: maximumEntries, settings: settings, visited: &visited, entries: &entries)
                    : false
                if !settings.showEmptyFolders, childEmitted {
                    entries.insert(ProjectTreeEntry(rootID: rootID, logicalPath: relative, isDirectory: true, size: nil), at: insertion)
                }
                emitted = emitted || settings.showEmptyFolders || childEmitted
            } else {
                entries.append(ProjectTreeEntry(rootID: rootID, logicalPath: relative, isDirectory: false, size: Int64(resolvedValues.fileSize ?? 0)))
                emitted = true
            }
        }
        return emitted
    }

    private func scanFiles(
        request: ProjectSearchRequest,
        rootPath: String,
        currentPath: String,
        maximumResults: Int,
        maximumFileBytes: Int,
        expression: NSRegularExpression?,
        settings: AdvancedServerSettings,
        visited: inout Set<String>,
        hits: inout [ProjectSearchHit]
    ) throws {
        guard hits.count < maximumResults else { return }
        let canonical = URL(fileURLWithPath: currentPath).resolvingSymlinksInPath().standardizedFileURL.path
        guard Self.isInside(canonical, root: rootPath), visited.insert(canonical).inserted else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: currentPath, isDirectory: &isDirectory) else { return }
        if !isDirectory.boolValue {
            try appendSearchHits(
                from: URL(fileURLWithPath: currentPath),
                request: request,
                rootPath: rootPath,
                maximumResults: maximumResults,
                maximumFileBytes: maximumFileBytes,
                expression: expression,
                hits: &hits
            )
            return
        }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: currentPath), includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard hits.count < maximumResults else { return }
            let relative = Self.relativePath(url.path, root: rootPath)
            guard !Self.isIgnored(relativePath: relative, rootPath: rootPath, settings: settings) else { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true, !settings.followSymbolicLinks { continue }
            let resolvedURL = values.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
            guard Self.isInside(resolvedURL.path, root: rootPath) else { continue }
            let resolvedValues = try resolvedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if resolvedValues.isDirectory == true {
                try scanFiles(request: request, rootPath: rootPath, currentPath: resolvedURL.path, maximumResults: maximumResults, maximumFileBytes: maximumFileBytes, expression: expression, settings: settings, visited: &visited, hits: &hits)
                continue
            }
            guard resolvedValues.isRegularFile == true else { continue }
            try appendSearchHits(
                from: resolvedURL,
                request: request,
                rootPath: rootPath,
                maximumResults: maximumResults,
                maximumFileBytes: maximumFileBytes,
                expression: expression,
                hits: &hits
            )
        }
    }

    private func appendSearchHits(
        from url: URL,
        request: ProjectSearchRequest,
        rootPath: String,
        maximumResults: Int,
        maximumFileBytes: Int,
        expression: NSRegularExpression?,
        hits: inout [ProjectSearchHit]
    ) throws {
        guard hits.count < maximumResults else { return }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumFileBytes else { return }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let content = String(data: data, encoding: .utf8) else { return }
        let relative = Self.relativePath(url.path, root: rootPath)
        for (offset, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            let matched = if let expression {
                expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            } else {
                text.localizedCaseInsensitiveContains(request.query)
            }
            if matched {
                hits.append(ProjectSearchHit(rootID: request.rootID, logicalPath: relative, line: offset + 1, preview: String(text.prefix(1000))))
                if hits.count >= maximumResults { return }
            }
        }
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        let canonicalRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return canonicalPath == canonicalRoot || canonicalPath.hasPrefix(canonicalRoot + "/")
    }

    /// Desktop `IgnoreRulesManager.makeRootRules`: `.gitignore` always loads, then
    /// `globalIgnoreDefaults`, then gated `.repo_ignore` / `.cursorignore`.
    private static func isIgnored(relativePath: String, rootPath: String, settings: AdvancedServerSettings) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        let directoryCount = max(0, components.count - 1)
        let depths = settings.respectNestedIgnoreFiles ? Array(0 ... directoryCount) : [0]
        var ignored = false
        for depth in depths {
            let base = components.prefix(depth).joined(separator: "/")
            let directory = base.isEmpty ? rootPath : URL(fileURLWithPath: rootPath).appendingPathComponent(base).path
            let candidate = components.dropFirst(depth).joined(separator: "/")
            applyIgnoreFile(named: ".gitignore", in: directory, candidate: candidate, ignored: &ignored)
            if depth == 0 {
                applyIgnoreText(settings.globalIgnoreDefaults, candidate: candidate, ignored: &ignored)
            }
            if settings.respectRepoIgnore {
                applyIgnoreFile(named: ".repo_ignore", in: directory, candidate: candidate, ignored: &ignored)
            }
            if settings.respectCursorIgnore {
                applyIgnoreFile(named: ".cursorignore", in: directory, candidate: candidate, ignored: &ignored)
            }
        }
        return ignored
    }

    private static func applyIgnoreFile(named name: String, in directory: String, candidate: String, ignored: inout Bool) {
        guard let text = try? String(
            contentsOfFile: URL(fileURLWithPath: directory).appendingPathComponent(name).path,
            encoding: .utf8
        ) else { return }
        applyIgnoreText(text, candidate: candidate, ignored: &ignored)
    }

    private static func applyIgnoreText(_ text: String, candidate: String, ignored: inout Bool) {
        let leaf = candidate.split(separator: "/").map(String.init).last ?? candidate
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let negated = line.hasPrefix("!")
            let pattern = negated ? String(line.dropFirst()) : line
            if glob(pattern, matches: candidate) || glob(pattern, matches: leaf) {
                ignored = !negated
            }
        }
    }

    private static func glob(_ pattern: String, matches value: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var expression = "^"
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character == "*" {
                let next = trimmed.index(after: index)
                if next < trimmed.endIndex, trimmed[next] == "*" {
                    let afterStar = trimmed.index(after: next)
                    if afterStar < trimmed.endIndex, trimmed[afterStar] == "/" {
                        expression += "(?:.*/)?"
                        index = trimmed.index(after: afterStar)
                        continue
                    }
                    expression += ".*"
                    index = afterStar
                    continue
                }
                expression += "[^/]*"
                index = next
                continue
            }
            if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = trimmed.index(after: index)
        }
        if pattern.hasSuffix("/") { expression += "(?:/.*)?" }
        expression += "$"
        return value.range(of: expression, options: .regularExpression) != nil
    }

    private static func relativePath(_ path: String, root: String) -> String {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.filter { $0 != "/" }
        let rootComponents = URL(fileURLWithPath: root).standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard !rootComponents.isEmpty, pathComponents.count >= rootComponents.count else { return URL(fileURLWithPath: path).lastPathComponent }
        for start in 0 ... (pathComponents.count - rootComponents.count) where Array(pathComponents[start ..< start + rootComponents.count]) == rootComponents {
            return pathComponents.dropFirst(start + rootComponents.count).joined(separator: "/")
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func safeRevision(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.range(of: "^[A-Za-z0-9_./~^{}-]+$", options: .regularExpression) != nil
    }
}

enum WorktreeRuntimeIdentity {
    static func digest(
        path: String,
        runner: any WorkspaceCommandRunning,
        gitExecutable: String
    ) async throws -> String {
        let filesystemIdentity = try LocalFilesystemAuthority().canonicalizeRoot(path).identity
        let rawCommonDirectory = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", path, "rev-parse", "--git-common-dir"],
            workingDirectory: path,
            maximumBytes: 65536
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDirectory = URL(
            fileURLWithPath: rawCommonDirectory,
            relativeTo: URL(fileURLWithPath: path, isDirectory: true)
        ).standardizedFileURL.resolvingSymlinksInPath().path
        return PortableContentDigest.sha256Hex(Data("\(filesystemIdentity)\u{0}\(commonDirectory)".utf8))
    }
}

public struct ProjectExecutionWorkspace: Sendable {
    public struct Root: Sendable {
        public let rootID: UUID
        public let logicalName: String
        public let routePath: String
        public let executionPath: String
        public let writable: Bool

        public init(rootID: UUID, logicalName: String, routePath: String, executionPath: String, writable: Bool) {
            self.rootID = rootID
            self.logicalName = logicalName
            self.routePath = routePath
            self.executionPath = executionPath
            self.writable = writable
        }
    }

    public let directory: String
    public let roots: [Root]

    public init(directory: String, roots: [Root]) {
        self.directory = directory
        self.roots = roots
    }

    public var writableRoots: [String] {
        roots.filter(\.writable).map(\.executionPath)
    }
}

public actor WorktreeRuntimeService {
    private let baseDirectory: String
    private let pinnedBase: PinnedFilesystemRoot
    private let runner: any WorkspaceCommandRunning
    private let gitExecutable: String
    private let resources: (any OwnedResourceRepository)?
    private let filesystem: any FilesystemAuthorityPort
    private let ownerInstanceID: UUID

    public init(
        baseDirectory: String,
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        gitExecutable: String = "/usr/bin/git",
        resources: (any OwnedResourceRepository)? = nil,
        filesystem: any FilesystemAuthorityPort = LocalFilesystemAuthority(),
        ownerInstanceID: UUID = UUID()
    ) throws {
        let standardized = URL(fileURLWithPath: baseDirectory).standardized.path
        let pinnedBase = try PinnedFilesystemRoot.createDirectoryTreeAndPin(at: standardized)
        try pinnedBase.validateReachableIdentity()
        self.baseDirectory = standardized
        self.pinnedBase = pinnedBase
        self.runner = runner
        self.gitExecutable = gitExecutable
        self.resources = resources
        self.filesystem = filesystem
        self.ownerInstanceID = ownerInstanceID
    }

    public func materializeExecutionWorkspace(
        project: ProjectSnapshot,
        ownerSessionID: UUID,
        bindings: [WorktreeBindingSnapshot],
        readOnlyRootIdentities: [UUID: String]
    ) async throws -> ProjectExecutionWorkspace {
        try pinnedBase.validateReachableIdentity()
        guard Set(project.roots.map(\.rootID)).count == project.roots.count else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Project execution roots contain duplicate identities", retryable: false)
        }
        let readOnlyRootIDs = Set(project.roots.filter { !$0.writable }.map(\.rootID))
        guard Set(readOnlyRootIdentities.keys) == readOnlyRootIDs else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Read-only project root identities are incomplete")
        }
        let active = bindings.filter { $0.ownershipState == .active }
        guard active.allSatisfy({ binding in
            binding.projectID == project.projectID
                && binding.sessionID == ownerSessionID
                && project.roots.contains(where: { $0.rootID == binding.rootID })
        }) else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Execution workspace contains a foreign worktree binding")
        }
        let byRoot = Dictionary(grouping: active, by: \.rootID)
        let executionRootURL = URL(fileURLWithPath: baseDirectory).appendingPathComponent(".execution-workspaces", isDirectory: true)
        let projectDirectoryURL = executionRootURL.appendingPathComponent(project.projectID.uuidString.lowercased(), isDirectory: true)
        let destination = projectDirectoryURL.appendingPathComponent(ownerSessionID.uuidString.lowercased(), isDirectory: true)
        let staging = projectDirectoryURL.appendingPathComponent(".\(ownerSessionID.uuidString.lowercased()).\(UUID().uuidString).tmp", isDirectory: true)
        _ = try Self.lexicallyContainedPath(root: baseDirectory, candidate: destination.path)
        _ = try Self.lexicallyContainedPath(root: baseDirectory, candidate: staging.path)
        let executionRoot = try pinnedBase.createDirectory(at: executionRootURL.path)
        let projectDirectory = try executionRoot.createDirectory(at: projectDirectoryURL.path)
        let stagingDirectory = try projectDirectory.createDirectory(at: staging.path, permissions: 0o700)
        let stagingRoots = try stagingDirectory.createDirectory(at: staging.appendingPathComponent("roots", isDirectory: true).path, permissions: 0o700)
        var published = false
        do {
            var routed: [ProjectExecutionWorkspace.Root] = []
            var manifestRoots: [[String: Any]] = []
            for root in project.roots {
                let candidates = byRoot[root.rootID] ?? []
                let executionPath: String
                if root.writable {
                    guard candidates.count == 1, let binding = candidates.first else {
                        throw ServiceAPIError(code: .worktreeConflict, message: "Every writable project root requires exactly one active session worktree")
                    }
                    executionPath = try Self.lexicallyContainedPath(root: baseDirectory, candidate: binding.physicalPath)
                    try PinnedFilesystemRoot.validateDirectoryChain(at: executionPath)
                    if let resources {
                        let identityDigest = try await WorktreeRuntimeIdentity.digest(path: executionPath, runner: runner, gitExecutable: gitExecutable)
                        guard let resource = try await resources.ownedResource(externalID: binding.bindingID, kind: .worktree),
                              [.prepared, .active].contains(resource.lifecycleState),
                              resource.projectID == project.projectID,
                              resource.sessionID == ownerSessionID,
                              resource.internalPathIdentity == executionPath,
                              resource.contentDigest == identityDigest,
                              resource.metadata["sourceRoot"] == root.canonicalPath,
                              resource.metadata["branch"] == binding.branch
                        else {
                            throw ServiceAPIError(code: .worktreeConflict, message: "Session worktree ownership record is invalid")
                        }
                    }
                    let verification = try await runner.run(
                        executable: gitExecutable,
                        arguments: ["-C", executionPath, "rev-parse", "--show-toplevel"],
                        workingDirectory: executionPath,
                        maximumBytes: 65536
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    let registration = try await runner.run(
                        executable: gitExecutable,
                        arguments: ["-C", root.canonicalPath, "worktree", "list", "--porcelain"],
                        workingDirectory: root.canonicalPath,
                        maximumBytes: 1_048_576
                    )
                    let registeredPaths = registration.split(separator: "\n").compactMap { line -> String? in
                        let prefix = "worktree "
                        guard line.hasPrefix(prefix) else { return nil }
                        return URL(fileURLWithPath: String(line.dropFirst(prefix.count))).standardizedFileURL.path
                    }
                    guard URL(fileURLWithPath: verification).standardizedFileURL.path == executionPath,
                          registeredPaths.contains(executionPath)
                    else {
                        throw ServiceAPIError(code: .worktreeConflict, message: "Session worktree identity is invalid")
                    }
                } else {
                    guard candidates.isEmpty,
                          let expectedIdentity = readOnlyRootIdentities[root.rootID],
                          !expectedIdentity.isEmpty,
                          !["pending", "legacy-import", "unavailable"].contains(expectedIdentity)
                    else {
                        throw ServiceAPIError(code: .rootUnauthorized, message: "Read-only project root identity is unavailable")
                    }
                    try PinnedFilesystemRoot.validateDirectoryChain(at: root.canonicalPath)
                    let canonical = try filesystem.canonicalizeRoot(root.canonicalPath)
                    guard canonical.path == root.canonicalPath, canonical.identity == expectedIdentity else {
                        throw ServiceAPIError(code: .rootUnauthorized, message: "Read-only project root identity changed")
                    }
                    executionPath = canonical.path
                }
                let rootName = root.rootID.uuidString.lowercased()
                let relativePath = "roots/\(rootName)"
                try stagingRoots.createSymbolicLink(named: rootName, destination: executionPath)
                routed.append(.init(
                    rootID: root.rootID,
                    logicalName: root.logicalName,
                    routePath: destination.appendingPathComponent(relativePath).path,
                    executionPath: executionPath,
                    writable: root.writable
                ))
                manifestRoots.append([
                    "rootId": rootName,
                    "logicalName": root.logicalName,
                    "relativePath": relativePath,
                    "writable": root.writable
                ])
            }
            let manifest: [String: Any] = [
                "schemaVersion": 1,
                "projectId": project.projectID.uuidString.lowercased(),
                "ownerSessionId": ownerSessionID.uuidString.lowercased(),
                "roots": manifestRoots
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            if let existing = try projectDirectory.directoryIfExists(at: destination.path) {
                guard try existing.readFile(named: "workspace.json") == manifestData,
                      let existingRoots = try existing.directoryIfExists(at: destination.appendingPathComponent("roots", isDirectory: true).path)
                else {
                    throw ServiceAPIError(code: .worktreeConflict, message: "Published execution workspace manifest changed")
                }
                for root in routed {
                    let target = try existingRoots.symbolicLinkDestination(named: root.rootID.uuidString.lowercased())
                    guard URL(fileURLWithPath: target).standardized.path == root.executionPath else {
                        throw ServiceAPIError(code: .worktreeConflict, message: "Published execution workspace route changed")
                    }
                }
                try Self.prepareExecutionWorkspaceForRemoval(parent: projectDirectory, workspaceURL: staging)
                try projectDirectory.removeTree(at: staging.path)
                try pinnedBase.validateReachableIdentity()
                return ProjectExecutionWorkspace(directory: destination.path, roots: routed)
            }
            try stagingDirectory.writeFile(named: "workspace.json", data: manifestData)
            try stagingRoots.setPermissions(0o555)
            try stagingDirectory.setPermissions(0o555)
            try projectDirectory.moveAtomically(from: staging.path, to: destination.path)
            published = true
            guard try projectDirectory.directoryIfExists(at: destination.path) != nil else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Published execution workspace identity was lost")
            }
            try pinnedBase.validateReachableIdentity()
            return ProjectExecutionWorkspace(directory: destination.path, roots: routed)
        } catch {
            let cleanupURL = published ? destination : staging
            try? Self.prepareExecutionWorkspaceForRemoval(parent: projectDirectory, workspaceURL: cleanupURL)
            try? projectDirectory.removeTree(at: cleanupURL.path)
            throw error
        }
    }

    public func discardPrepared(_ binding: WorktreeBindingSnapshot, sourceRoot: String) async {
        let cleanupError = await cleanupFailedWorktree(path: binding.physicalPath, sourceRoot: sourceRoot)
        if cleanupError == nil {
            _ = try? await runner.run(
                executable: gitExecutable,
                arguments: ["-C", sourceRoot, "branch", "-D", binding.branch],
                workingDirectory: sourceRoot,
                maximumBytes: 65536
            )
        }
        if let resource = try? await resources?.ownedResource(externalID: binding.bindingID, kind: .worktree) {
            _ = try? await resources?.transitionOwnedResource(
                resourceID: resource.resourceID,
                expectedStates: [.preparing, .prepared],
                to: cleanupError == nil ? .failed : .quarantined,
                observedBytes: nil,
                contentDigest: nil,
                cleanupError: cleanupError
            )
        }
    }

    public func removeExecutionWorkspace(projectID: UUID, ownerSessionID: UUID) throws {
        try pinnedBase.validateReachableIdentity()
        let executionRootURL = URL(fileURLWithPath: baseDirectory).appendingPathComponent(".execution-workspaces", isDirectory: true)
        guard let executionRoot = try pinnedBase.directoryIfExists(at: executionRootURL.path) else { return }
        let projectDirectoryURL = executionRootURL.appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
        guard let projectDirectory = try executionRoot.directoryIfExists(at: projectDirectoryURL.path) else { return }
        let workspace = projectDirectoryURL.appendingPathComponent(ownerSessionID.uuidString.lowercased(), isDirectory: true)
        guard try projectDirectory.directoryIfExists(at: workspace.path) != nil else { return }
        try Self.prepareExecutionWorkspaceForRemoval(parent: projectDirectory, workspaceURL: workspace)
        try projectDirectory.removeTree(at: workspace.path)
        try pinnedBase.validateReachableIdentity()
    }

    public func removeOrphanedExecutionWorkspaces(validOwnerSessionIDs: Set<UUID>) throws {
        try pinnedBase.validateReachableIdentity()
        let executionRootURL = URL(fileURLWithPath: baseDirectory).appendingPathComponent(".execution-workspaces", isDirectory: true)
        guard let executionRoot = try pinnedBase.directoryIfExists(at: executionRootURL.path) else { return }
        for projectName in try executionRoot.directoryEntryNames() {
            let projectDirectoryURL = executionRootURL.appendingPathComponent(projectName, isDirectory: true)
            guard let projectDirectory = try executionRoot.directoryIfExists(at: projectDirectoryURL.path) else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Execution workspace project entry is unsafe")
            }
            for workspaceName in try projectDirectory.directoryEntryNames() {
                let workspace = projectDirectoryURL.appendingPathComponent(workspaceName, isDirectory: true)
                guard try projectDirectory.directoryIfExists(at: workspace.path) != nil else {
                    throw ServiceAPIError(code: .rootUnauthorized, message: "Execution workspace session entry is unsafe")
                }
                if let ownerID = UUID(uuidString: workspaceName), validOwnerSessionIDs.contains(ownerID) { continue }
                try Self.prepareExecutionWorkspaceForRemoval(parent: projectDirectory, workspaceURL: workspace)
                try projectDirectory.removeTree(at: workspace.path)
            }
        }
        try pinnedBase.validateReachableIdentity()
    }

    public func create(project: ProjectSnapshot, root: ProjectRootSnapshot, sessionID: UUID, baseRef: String, branch: String) async throws -> WorktreeBindingSnapshot {
        guard root.writable else { throw ServiceAPIError(code: .rootUnauthorized, message: "Worktree root is read-only") }
        guard Self.safeRef(baseRef), Self.safeBranch(branch) else { throw ServiceAPIError(code: .invalidRequest, message: "Worktree ref or branch is invalid") }
        let bindingID = UUID()
        let candidate = URL(fileURLWithPath: baseDirectory).appendingPathComponent(project.projectID.uuidString).appendingPathComponent(bindingID.uuidString).path
        let path = try Self.lexicallyContainedPath(root: baseDirectory, candidate: candidate)
        let reservation = OwnedResourceRecord(
            kind: .worktree,
            projectID: project.projectID,
            sessionID: sessionID,
            externalID: bindingID,
            internalPathIdentity: path,
            lifecycleState: .preparing,
            metadata: ["sourceRoot": root.canonicalPath, "baseRef": baseRef, "branch": branch],
            retentionDeadline: Date().addingTimeInterval(15 * 60)
        )
        try await resources?.reserveOwnedResource(reservation)
        try pinnedBase.validateReachableIdentity()
        _ = try pinnedBase.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        do {
            _ = try await runner.run(executable: gitExecutable, arguments: ["-C", root.canonicalPath, "worktree", "add", "-b", branch, path, baseRef], workingDirectory: root.canonicalPath, maximumBytes: 65536)
            let verification = try await runner.run(executable: gitExecutable, arguments: ["-C", path, "rev-parse", "--show-toplevel"], workingDirectory: path, maximumBytes: 65536)
            guard URL(fileURLWithPath: verification.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path == path else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Created Git worktree identity did not match its reservation")
            }
            try pinnedBase.validateReachableIdentity()
            if resources != nil { try PinnedFilesystemRoot.validateDirectoryChain(at: path) }
            let identityDigest: String? = if resources == nil {
                nil
            } else {
                try await WorktreeRuntimeIdentity.digest(path: path, runner: runner, gitExecutable: gitExecutable)
            }
            _ = try await resources?.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing],
                to: .prepared,
                observedBytes: nil,
                contentDigest: identityDigest,
                cleanupError: nil
            )
            return WorktreeBindingSnapshot(bindingID: bindingID, projectID: project.projectID, rootID: root.rootID, sessionID: sessionID, baseRef: baseRef, branch: branch, physicalPath: path, ownershipState: .active, mergeState: .clean, revision: 1)
        } catch {
            let cleanupError = await cleanupFailedWorktree(path: path, sourceRoot: root.canonicalPath)
            _ = try? await resources?.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing, .prepared],
                to: cleanupError == nil ? .failed : .quarantined,
                observedBytes: nil,
                contentDigest: nil,
                cleanupError: cleanupError
            )
            throw error
        }
    }

    public func merge(_ binding: WorktreeBindingSnapshot, targetPath: String, strategy: String) async throws -> WorktreeBindingSnapshot {
        guard ["merge", "squash"].contains(strategy) else { throw ServiceAPIError(code: .invalidRequest, message: "Unsupported worktree merge strategy") }
        guard binding.ownershipState == .active else { throw ServiceAPIError(code: .worktreeConflict, message: "Only an active worktree can be merged") }
        let preMergeStatus = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", targetPath, "status", "--porcelain"],
            workingDirectory: targetPath,
            maximumBytes: 65536
        )
        guard preMergeStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Merge target must be clean before acquiring a lease")
        }
        let preMergeHead = try await runner.run(executable: gitExecutable, arguments: ["-C", targetPath, "rev-parse", "HEAD"], workingDirectory: targetPath, maximumBytes: 4096).trimmingCharacters(in: .whitespacesAndNewlines)
        let lease = WorktreeMergeLeaseRecord(
            bindingID: binding.bindingID,
            expectedBindingRevision: binding.revision,
            strategy: strategy,
            targetPath: URL(fileURLWithPath: targetPath).standardizedFileURL.path,
            preMergeHead: preMergeHead,
            ownerInstanceID: ownerInstanceID,
            expiresAt: Date().addingTimeInterval(2 * 60)
        )
        try await resources?.acquireWorktreeMergeLease(lease)
        _ = try await resources?.transitionWorktreeMergeLease(leaseID: lease.leaseID, expectedStates: [.preparing], to: .running, conflictArtifactPath: nil, errorCode: nil)
        let leaseHeartbeat = resources.map { resources in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { break }
                    try? await resources.renewWorktreeMergeLease(
                        leaseID: lease.leaseID,
                        ownerInstanceID: ownerInstanceID,
                        expiresAt: Date().addingTimeInterval(2 * 60)
                    )
                }
            }
        }
        defer { leaseHeartbeat?.cancel() }
        do {
            var arguments = ["-C", targetPath, "merge", "--no-edit"]
            if strategy == "squash" { arguments.append("--squash") }
            arguments.append(binding.branch)
            _ = try await runner.run(executable: gitExecutable, arguments: arguments, workingDirectory: targetPath, maximumBytes: 1_048_576)
            _ = try await resources?.transitionWorktreeMergeLease(leaseID: lease.leaseID, expectedStates: [.running], to: .prepared, conflictArtifactPath: nil, errorCode: nil)
            return WorktreeBindingSnapshot(bindingID: binding.bindingID, projectID: binding.projectID, rootID: binding.rootID, sessionID: binding.sessionID, baseRef: binding.baseRef, branch: binding.branch, physicalPath: binding.physicalPath, ownershipState: binding.ownershipState, mergeState: .merged, revision: binding.revision + 1)
        } catch {
            let conflictPath = try? await publishConflictSnapshot(binding: binding, lease: lease, targetPath: targetPath)
            _ = try? await resources?.transitionWorktreeMergeLease(
                leaseID: lease.leaseID,
                expectedStates: [.running, .preparing],
                to: .conflicted,
                conflictArtifactPath: conflictPath,
                errorCode: "git_merge_failed"
            )
            throw ServiceAPIError(code: .worktreeConflict, message: "Worktree merge requires conflict recovery")
        }
    }

    public func abortConflictedMerge(
        _ binding: WorktreeBindingSnapshot,
        targetPath: String,
        leaseID: UUID
    ) async throws -> WorktreeBindingSnapshot {
        guard let resources else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Durable merge recovery requires an owned-resource repository")
        }
        let leases = try await resources.worktreeMergeLeases(nonterminalOnly: true)
        guard let lease = leases.first(where: { $0.leaseID == leaseID }),
              lease.bindingID == binding.bindingID,
              lease.state == .conflicted,
              lease.targetPath == URL(fileURLWithPath: targetPath).standardizedFileURL.path
        else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Conflicted merge lease does not match the requested binding")
        }
        do {
            _ = try await runner.run(
                executable: gitExecutable,
                arguments: ["-C", targetPath, "merge", "--abort"],
                workingDirectory: targetPath,
                maximumBytes: 65536
            )
        } catch {
            _ = try await runner.run(
                executable: gitExecutable,
                arguments: ["-C", targetPath, "reset", "--merge", lease.preMergeHead],
                workingDirectory: targetPath,
                maximumBytes: 65536
            )
        }
        let recoveredHead = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", targetPath, "rev-parse", "HEAD"],
            workingDirectory: targetPath,
            maximumBytes: 4096
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveredStatus = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", targetPath, "status", "--porcelain"],
            workingDirectory: targetPath,
            maximumBytes: 65536
        )
        guard recoveredHead == lease.preMergeHead,
              recoveredStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Merge abort did not restore the fenced clean pre-merge state")
        }
        _ = try await resources.transitionWorktreeMergeLease(
            leaseID: leaseID,
            expectedStates: [.conflicted],
            to: .aborted,
            conflictArtifactPath: lease.conflictArtifactPath,
            errorCode: nil
        )
        return WorktreeBindingSnapshot(
            bindingID: binding.bindingID,
            projectID: binding.projectID,
            rootID: binding.rootID,
            sessionID: binding.sessionID,
            baseRef: binding.baseRef,
            branch: binding.branch,
            physicalPath: binding.physicalPath,
            ownershipState: binding.ownershipState,
            mergeState: .clean,
            revision: binding.revision + 1
        )
    }

    private func cleanupFailedWorktree(path: String, sourceRoot: String) async -> String? {
        do {
            if FileManager.default.fileExists(atPath: path) {
                _ = try await runner.run(executable: gitExecutable, arguments: ["-C", sourceRoot, "worktree", "remove", "--force", path], workingDirectory: sourceRoot, maximumBytes: 65536)
            }
            _ = try await runner.run(executable: gitExecutable, arguments: ["-C", sourceRoot, "worktree", "prune"], workingDirectory: sourceRoot, maximumBytes: 65536)
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            return nil
        } catch {
            return "worktree_cleanup_failed"
        }
    }

    private func publishConflictSnapshot(binding: WorktreeBindingSnapshot, lease: WorktreeMergeLeaseRecord, targetPath: String) async throws -> String {
        let directory = URL(fileURLWithPath: baseDirectory).appendingPathComponent(".conflicts", isDirectory: true)
        let destination = directory.appendingPathComponent("\(lease.leaseID.uuidString).json")
        let temporary = directory.appendingPathComponent(".\(lease.leaseID.uuidString).tmp")
        let payload = try JSONEncoder().encode([
            "schemaVersion": "1", "bindingId": binding.bindingID.uuidString, "leaseId": lease.leaseID.uuidString,
            "strategy": lease.strategy, "preMergeHead": lease.preMergeHead, "targetState": "conflicted"
        ])
        try DurableFilesystem.publish(data: payload, temporary: temporary, destination: destination)
        let record = OwnedResourceRecord(
            kind: .mergeConflict,
            projectID: binding.projectID,
            sessionID: binding.sessionID,
            externalID: lease.leaseID,
            internalPathIdentity: destination.path,
            lifecycleState: .active,
            observedBytes: Int64(payload.count),
            contentDigest: PortableContentDigest.sha256Hex(payload),
            metadata: ["bindingId": binding.bindingID.uuidString]
        )
        try await resources?.reserveOwnedResource(record)
        return destination.path
    }

    private static func prepareExecutionWorkspaceForRemoval(parent: PinnedFilesystemRoot, workspaceURL: URL) throws {
        guard let workspace = try parent.directoryIfExists(at: workspaceURL.path) else { return }
        try workspace.setPermissions(0o700)
        if let roots = try workspace.directoryIfExists(at: workspaceURL.appendingPathComponent("roots", isDirectory: true).path) {
            try roots.setPermissions(0o700)
        }
    }

    private static func lexicallyContainedPath(root: String, candidate: String) throws -> String {
        let rootPath = URL(fileURLWithPath: root).standardized.path
        let candidatePath = URL(fileURLWithPath: candidate).standardized.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix), candidatePath != rootPath else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Service-owned path escaped its configured root")
        }
        return candidatePath
    }

    private static func requireNonSymbolicLinkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Execution workspace scaffold is unsafe")
        }
    }

    private static func safeRef(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.range(of: "^[A-Za-z0-9_./~^{}-]+$", options: .regularExpression) != nil
    }

    private static func safeBranch(_ value: String) -> Bool {
        safeRef(value) && !value.contains("..") && !value.hasSuffix(".lock")
    }
}

public actor ArtifactRuntimeService {
    private let baseDirectory: String
    private let resources: (any OwnedResourceRepository)?

    public init(baseDirectory: String, resources: (any OwnedResourceRepository)? = nil) throws {
        self.baseDirectory = URL(fileURLWithPath: baseDirectory).standardizedFileURL.path
        self.resources = resources
        try FileManager.default.createDirectory(atPath: self.baseDirectory, withIntermediateDirectories: true)
    }

    public func store(projectID: UUID, sessionID: UUID?, kind: String, logicalName: String, content: Data, cursor: ServiceCursor) async throws -> (ArtifactSnapshot, storageReference: String) {
        guard content.count <= 64 * 1024 * 1024 else { throw ServiceAPIError(code: .invalidRequest, message: "Artifact exceeds the 64 MiB service limit") }
        let artifactID = UUID()
        let projectDirectory = URL(fileURLWithPath: baseDirectory).appendingPathComponent(projectID.uuidString)
        let destination = projectDirectory.appendingPathComponent(artifactID.uuidString)
        let temporary = projectDirectory.appendingPathComponent(".\(artifactID.uuidString).tmp")
        let finalPath = try DurableFilesystem.standardizedContainedPath(root: baseDirectory, candidate: destination.path)
        let temporaryPath = try DurableFilesystem.standardizedContainedPath(root: baseDirectory, candidate: temporary.path)
        let digest = PortableContentDigest.sha256Hex(content)
        let reservation = OwnedResourceRecord(
            kind: .artifact,
            projectID: projectID,
            sessionID: sessionID,
            externalID: artifactID,
            internalPathIdentity: finalPath,
            temporaryPathIdentity: temporaryPath,
            lifecycleState: .preparing,
            observedBytes: Int64(content.count),
            contentDigest: digest,
            metadata: ["kind": kind, "logicalName": logicalName],
            retentionDeadline: Date().addingTimeInterval(15 * 60)
        )
        try await resources?.reserveOwnedResource(reservation)
        do {
            try DurableFilesystem.publish(data: content, temporary: URL(fileURLWithPath: temporaryPath), destination: URL(fileURLWithPath: finalPath))
            let persisted = try Data(contentsOf: URL(fileURLWithPath: finalPath), options: [.mappedIfSafe])
            guard persisted.count == content.count, PortableContentDigest.sha256Hex(persisted) == digest else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Published artifact failed durability verification")
            }
            _ = try await resources?.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing],
                to: .prepared,
                observedBytes: Int64(content.count),
                contentDigest: digest,
                cleanupError: nil
            )
            return (ArtifactSnapshot(artifactID: artifactID, projectID: projectID, sessionID: sessionID, kind: kind, logicalName: logicalName, contentDigest: digest, size: Int64(content.count), createdCursor: cursor), finalPath)
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            _ = try? await resources?.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing, .prepared],
                to: FileManager.default.fileExists(atPath: finalPath) ? .quarantined : .failed,
                observedBytes: Int64(content.count),
                contentDigest: digest,
                cleanupError: FileManager.default.fileExists(atPath: finalPath) ? "artifact_publication_unconfirmed" : nil
            )
            throw error
        }
    }

    public func content(storageReference: String, maximumBytes: Int) throws -> Data {
        let path = URL(fileURLWithPath: storageReference).standardizedFileURL.path
        let prefix = baseDirectory.hasSuffix("/") ? baseDirectory : baseDirectory + "/"
        guard path.hasPrefix(prefix) else { throw ServiceAPIError(code: .rootUnauthorized, message: "Artifact storage reference escaped its service root") }
        return try Data(Data(contentsOf: URL(fileURLWithPath: path)).prefix(max(1, min(maximumBytes, 64 * 1024 * 1024))))
    }
}

public struct BuiltinWorkflowCatalog: Sendable {
    public init() {}

    public func workflows() throws -> [WorkflowSnapshot] {
        let canonicalOrder: [RepoPromptBuiltInAgentWorkflow] = [
            .investigate,
            .build,
            .oracleExport,
            .review,
            .refactor,
            .orchestrate,
            .optimize,
            .deepPlan
        ]
        return try canonicalOrder.map { workflow in
            guard let promptID = RepoPromptWorkflowID(rawValue: workflow.rawValue) else {
                throw ServiceAPIError(
                    code: .dependencyUnavailable,
                    message: "Canonical workflow identity is invalid"
                )
            }
            let definition = RepoPromptWorkflowPrompts.render(id: promptID, variant: .mcp)
            guard definition.contains("repoprompt_skills_version: 62"),
                  definition.contains("repoprompt_variant: mcp")
            else {
                throw ServiceAPIError(
                    code: .dependencyUnavailable,
                    message: "Canonical workflow catalog version is invalid"
                )
            }
            return WorkflowSnapshot(
                workflowID: promptID.commandName,
                source: "builtin",
                name: workflow.metadata.displayName,
                definition: definition,
                contentDigest: PortableContentDigest.sha256Hex(Data(definition.utf8)),
                enabled: true
            )
        }
    }
}
